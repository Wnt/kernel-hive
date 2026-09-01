// ============================================================================
//  analytics/instana — Instana EUM (End User Monitoring) configuration.
//  ---------------------------------------------------------------------------
//  Operator-decided, third-party, and NOT the same lane as everything else
//  under analytics/: every other module in this directory ships data to OUR
//  OWN box. This one ships beacons straight from each visitor's browser to
//  IBM/Instana's SaaS. The operator was told exactly that and asked for it
//  anyway — the goal is the richest possible dataset (page loads, every API
//  call, sessions, users, errors, backend correlation) to compare against our
//  home-grown telemetry and decide what to replicate. Do not re-litigate that
//  decision here; this module only has to implement it honestly.
//
//  `reportingUrl` and `key` are set earlier than this, in spa/index.html's
//  pre-React bootstrap — see the comment there for why (the agent script
//  needs them the instant it loads) and for the build-time env / no-key
//  fallback. This module is everything that can wait for a session id:
//  sessions, page detection, header correlation, error-capture wrapping,
//  secrets, the circular-monitoring exclusions, and identity.
// ============================================================================

import type { Session } from '../data/session';

/** The subset of the `ineum` call signature this module actually uses. */
type IneumFn = (...args: unknown[]) => void;

declare global {
  interface Window {
    /** Installed by the index.html bootstrap ONLY when the build is
     *  configured (a real website key was baked in). Absent otherwise — every
     *  call below must tolerate that. */
    ineum?: IneumFn;
  }
}

/** Guarded call: a no-op, silently, on an unconfigured build (no `window.ineum`
 *  at all) or outside a browser (tests, SSR-shaped tooling). Instrumentation
 *  must never throw into the app. */
function ineum(...args: unknown[]): void {
  try {
    if (typeof window === 'undefined') return;
    const fn = window.ineum;
    if (typeof fn === 'function') fn(...args);
  } catch {
    /* never throw */
  }
}

// -- secrets -----------------------------------------------------------------
// The default is [/key/i, /secret/i, /password/i], which matches nothing this
// app puts in a URL. Grepped the serving plane for what our own query strings
// actually carry (scripts/serve/signal_route.py, scripts/serve/auth/tickets.py)
// rather than guessing:
//
//   * `?traceparent=<32hex>-<16hex>-...` — signal_route.py mints this onto the
//     WebTransport URL the browser is handed, so the daemon's span can join
//     the browser's trace (docs/lab/TRACE-CONTEXT.md §3.1). The value is a
//     trace id, not a credential, but it is unique per session and worth
//     scrubbing on the same principle as any other request id.
//   * the stream TICKET is, on inspection, never a query parameter at all.
//     `tickets.mint()` (scripts/serve/auth/tickets.py) returns a PATH —
//     `/wt/<exp>.<nonce>.<sig>` — and that URL is only ever handed to
//     `new WebTransport(...)` (three/streamClient/transport.ts), never to
//     fetch/XHR. Instana's auto instrumentation patches XHR/fetch/resource
//     timing, none of which see a WebTransport connection, so this ticket
//     structurally cannot reach Instana through the mechanisms `secrets` or
//     `ignoreUrls` police. `secrets` also only redacts QUERY PARAMETER VALUES
//     by matching the parameter's KEY, so it could never scrub a path segment
//     even if the URL were reported. Kept anyway, for defense in depth and in
//     case a future code path ever turns a ticket into a query parameter.
export const SECRET_PATTERNS: RegExp[] = [/traceparent/i, /ticket/i];

// -- ignoreUrls ----------------------------------------------------------
// CIRCULAR MONITORING, by the docs' own name: without this, wrapEventHandlers/
// wrapTimers below make the agent's XHR/fetch wrapper report our OWN
// telemetry POSTs as ajax calls — noise next to real API calls, and it burns
// the exact per-tab beacon budget (128/10s, 4096/10min, 8096/page, XHR/fetch
// 32/10s) an Instana beacon about our own beacon would compete against every
// other beacon for. Paths verified against scripts/serve/telemetry_routes.py
// (`/analytics`, `/coverage`, `/traces`) and
// scripts/serve/osgallery-https-server.py (`/clientlog`, `/usage`,
// `/clientcmd`) rather than assumed from the brief.
//
// ONE LIST OF NAMES, TWO MATCHER SHAPES — the bug this section exists to fix.
// `khFetch.ts`'s `isExcludedPath` tests a pattern against `url.pathname`, a
// bare path with no origin (`/clientcmd`). `ineum('ignoreUrls', ...)` tests
// against the FULL URL string Instana's wrapped fetch/XHR sees
// (`https://kernelhive.madekivi.fi/clientcmd?since=64`). A pattern anchored
// `^\/` satisfies the first and can NEVER match the second — `^` binds to
// the start of the string, and a full URL starts with a scheme, not a
// slash — so reusing ONE such list for both consumers silently disabled
// Instana's filter. Measured live: in one 15-minute Instana beacon window,
// 77 `/clientcmd`, 76 `/clientlog`, 20 `/usage`, 20 `/analytics` and 5
// `/traces` calls, every one carrying the current bundle's `kh.bundle` meta —
// not stale tabs, the filter was simply never matching.
//
// The fix keeps the reuse instinct (a second hand-maintained list of
// patterns is exactly what would drift, as this list already had) but fixes
// what gets reused: `KH_TELEMETRY_PATHS` is the ONE list of ENDPOINT NAMES,
// and both matcher shapes below are MECHANICALLY DERIVED from it, so adding
// an endpoint here is the only place it has to be added for either consumer
// to see it. The two exports are named and shaped for their one legal
// consumer each — `IGNORE_URL_PATTERNS` for `khFetch.ts`'s pathname test,
// `INSTANA_IGNORE_URL_PATTERNS` for a full URL — so passing one where the
// other belongs reads wrong at the call site rather than merely misbehaving.
export const KH_TELEMETRY_PATHS = ['/traces', '/analytics', '/coverage', '/clientlog', '/usage', '/clientcmd'] as const;

/** Escape a literal path for embedding in a RegExp source string. None of
 *  the paths above contain regex metacharacters today, but a future
 *  endpoint might, and a silently-broken pattern is worse than a verbose one. */
function escapeForRegExp(literal: string): string {
  return literal.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** PATH form — anchored at the start of a bare pathname (`/clientcmd`, no
 *  origin, no query). The ONLY form `khFetch.ts`'s `isExcludedPath` may test
 *  a `url.pathname` against; this is the shape the original single list
 *  already had, unchanged in behaviour. */
export const IGNORE_URL_PATTERNS: RegExp[] = KH_TELEMETRY_PATHS.map(
  (path) => new RegExp(`^${escapeForRegExp(path)}\\b`),
);

/**
 * FULL-URL form — anchored at the start of a complete URL
 * (`https://kernelhive.madekivi.fi/clientcmd?since=64`). The ONLY form
 * `ineum('ignoreUrls', ...)` can ever match against — Instana's agent tests
 * the full URL string, never a bare pathname.
 *
 * NOT called from this module's `configureInstana` below. It has to reach
 * `ineum` from spa/index.html's inline bootstrap instead, alongside
 * `key`/`reportingUrl`/`trackSessions`/`enableW3CHeaders` — the same "before
 * the page-load beacon fires" reason defect 2/3 already moved those there:
 * Instana's wrapped fetch/XHR can beacon a request made before React (and
 * this module) ever evaluates, and an unfiltered pre-boot request is exactly
 * the class of noise this whole mechanism exists to suppress. index.html
 * cannot import this module — it is a plain inline script that must run
 * before any bundle evaluates — so it re-derives the same full-URL shape
 * from its own duplicated copy of `KH_TELEMETRY_PATHS`, the same "keep two
 * lists in sync by hand across the HTML/TS boundary" trade that file's
 * ROUTES table already makes for `page`. This export still exists, and is
 * still exercised by this file's tests: what matters is the MATCHING LOGIC
 * being correct, which the duplicate copy shares by construction (identical
 * derivation, copy-pasted) — not the export being called at runtime from
 * here. Testing that logic here is the fix for the second defect: the
 * absence of exactly this assertion (full URL, not pathname) is what let
 * the original list ship broken.
 */
export const INSTANA_IGNORE_URL_PATTERNS: RegExp[] = KH_TELEMETRY_PATHS.map(
  (path) => new RegExp(`^https?://[^/]+${escapeForRegExp(path)}\\b`),
);

/**
 * Everything that does not depend on WHO the visitor is, MINUS what defect
 * 2/3 moved into spa/index.html's inline bootstrap (`trackSessions`,
 * `enableW3CHeaders`, the initial pseudonymous `user` id, the initial `page`
 * name, and — per this file's `INSTANA_IGNORE_URL_PATTERNS` comment —
 * `ignoreUrls`) because it has to be set before the page-load beacon fires,
 * or before Instana's wrapped fetch/XHR can see a pre-boot request — see
 * that file's comment. Call this ONCE, as early as the session id exists,
 * gated by the SAME `allowed` answer `initAnalytics` uses (main.tsx) — an
 * unconfigured build or a signed-out stranger at the walk-in door must get
 * none of this.
 */
export function configureInstana(sessionId: string): void {
  // autoPageDetection: EXPLICITLY OFF, not left to either of the docs'
  // self-contradictory defaults. analytics/navigation.ts now drives every
  // route transition itself (a single router-level observer feeding BOTH
  // this vendor and our own plane — see that file's header for the whole
  // design) and calls `ineum('page', ...)` on each one. Leaving
  // autoPageDetection on at the same time would give Instana two mechanisms
  // naming the same transition — its own URL-change heuristic and our
  // explicit call — which structurally cannot agree on timing or on name
  // (ours is a route PATTERN; autoPageDetection's own default is closer to
  // the raw path/title) and would double the page-transition beacon count
  // for no gain. Explicit-and-ours was chosen over explicit-and-Instana's
  // specifically because our router already knows the pattern/param split
  // this whole integration wants (§ the cardinality rule in navigation.ts),
  // and because the operator wants OUR plane to work with Instana absent
  // entirely — an app that only knows how to name a page through a
  // third-party agent's internals is not that.
  //
  // THE COST, STATED RATHER THAN HIDDEN: Instana's docs (inconsistent
  // elsewhere, as already noted) describe recent agent versions timing a
  // page transition automatically under autoPageDetection — a number this
  // integration cannot ask the agent for once autoPageDetection is off. That
  // number is not lost: navigation.ts measures its own transition duration
  // (route commit to next paint, a double-`requestAnimationFrame` — the
  // same "two frames" heuristic browsers use elsewhere to mean "painted")
  // and records it durably in OUR OWN plane (`app.page.transitionMs`, and as
  // the `app.page` span's own duration — visible in /admin/observability
  // with Instana absent). What we can pass back to Instana is limited to
  // documented, ALREADY-VERIFIED call shapes (this file's own `meta` fix is
  // exactly what defect 1 exists to get right) — navigation.ts forwards it
  // as `ineum('meta', 'kh.page.transitionMs', ...)` rather than inventing an
  // unverified custom-event call this environment has no way to test against
  // the real agent (the vendor bundle on labhost is not world-readable, and
  // IBM's own docs page 403'd a fetch attempt while writing this). Best
  // effort, stated as such.
  ineum('autoPageDetection', false);
  // Both default OFF. They patch addEventListener/setTimeout/setInterval so
  // an exception thrown from inside a DOM handler or a timer callback is
  // still caught and reported. Without them Instana only sees errors that
  // reach window.onerror directly, which misses a large share of what
  // actually breaks in a WebGL/RAF/pointer-driven app like this one.
  ineum('wrapEventHandlers', true);
  ineum('wrapTimers', true);
  ineum('secrets', SECRET_PATTERNS);
  // NOT `ineum('ignoreUrls', ...)` here — see `INSTANA_IGNORE_URL_PATTERNS`'s
  // own comment above. It has to be set from spa/index.html's inline
  // bootstrap, before this call ever runs, so a request made before React
  // boots is filtered too.
  // THE JOIN — the point of the whole exercise. `kh.sessionId` is the same
  // value clientDebug.ts stamps on every /clientlog event and
  // analytics/trace.ts stamps as `session.id` on every OTel span this tab
  // sends to /traces, so an operator holding an Instana beacon can look up
  // this key and pull the matching kernel-hive trace from
  // /admin/observability, and vice versa.
  //
  // ONE CALL PER KEY. The documented signature is `ineum('meta', key,
  // value)` — a single string key and a single string value, not an object.
  // A previous version of this line called `ineum('meta', { ... })`, which
  // Instana's agent stringifies as its own object key (`'[object Object]':
  // 'undefined'` is exactly what that beacon carried in production) — the
  // join key this whole integration exists for was never actually sent.
  // Verified live: a page-load beacon queried from Instana's API carried
  // that literal malformed meta. So: one `ineum('meta', k, v)` call per
  // entry, both arguments coerced to string (Instana's own signature takes
  // strings only).
  ineum('meta', 'kh.sessionId', sessionId);
  // NOT `ineum('meta', 'kh.bundle', ...)` and NOT `ineum('meta',
  // 'kh.client.class', ...)` here anymore — DEFECT (walk-in-door
  // attribution gap): a signed-out stranger at the /walkin door never
  // reaches this function at all (`main.tsx`'s `signedOutAtTheDoor` gate
  // skips `configureInstana` entirely, and correctly so — see that gate's
  // own comment), but spa/index.html's inline bootstrap runs unconditionally,
  // before React and before that gate is even evaluated, and it is what
  // already emits the page-load/ajax beacons for exactly that visitor. A
  // beacon that exists but carries neither a build id nor a class label is
  // indistinguishable from a real human's on an unknown build — which is
  // exactly the traffic this lab's own visitor-sim and browser probes
  // produce. Both keys therefore moved to spa/index.html, set alongside
  // `key`/`reportingUrl`/`trackSessions`/etc. for the identical "must be on
  // every beacon, including one signed-out visitors ever produce" reason.
  // Calling either of them again here would be a harmless duplicate for a
  // signed-in visitor (same value) but is deliberately omitted so the split
  // stays legible: index.html is what MUST run unconditionally, this file is
  // what only runs once a session is allowed to be tracked at all.
  // NOT `ineum('user', sessionId)` here — that is now set in spa/index.html's
  // inline bootstrap, before this module even loads, for the reason stated
  // at this function's own header: the page-load beacon needs it and this
  // call runs after that beacon has already gone out. Calling it again here
  // would be harmless (same value) but is deliberately omitted so the split
  // stays legible: this file is what CAN wait, index.html is what cannot.
  // See configureInstanaIdentity for the upgrade once a real account exists.
}

/**
 * The identity update, once a real account is known. THIS SENDS THE REAL
 * ACCOUNT ID AND DISPLAY NAME TO INSTANA/IBM IN CLEARTEXT — the docs describe
 * no built-in hashing or scrubbing for `ineum('user', ...)`. That is a
 * deliberate operator decision, not an oversight or a bug: the operator was
 * told beacons (this one included) leave the browser for IBM, and chose it
 * anyway, in order to compare a real account's journey in Instana against the
 * same journey in our own telemetry.
 *
 * Anonymous visitors, and anyone `session.role === 'anon'` covers (including
 * a signed-out stranger at the /walkin door, who never gets this far because
 * `configureInstana` itself is never called for them — see main.tsx), are
 * left on the pseudonymous session id `configureInstana` already set. Never
 * send an empty or placeholder identity.
 *
 * SIGN-OUT / re-attribution: this app does not need a `terminateSession` call
 * anywhere. `SessionContext.tsx` documents why: the role is resolved once,
 * before React mounts, and "the role cannot change inside a document life —
 * signing out navigates." A full navigation tears down this page's JS realm
 * (and with it the Instana agent's in-page session object) and starts a
 * fresh one on reload, which already re-runs this exact configure sequence
 * with whatever session the new load resolves. There is no in-page transition
 * where a tab must keep running but stop being attributed to an account. The
 * one place an account IS created without a reload — self-service walk-in
 * signup, `walkin/WalkinLanding.tsx`'s `enrol()` — happens precisely for a
 * visitor `main.tsx` already gated out of analytics entirely
 * (`signedOutAtTheDoor`), so it never reaches this function either.
 */
export function configureInstanaIdentity(session: Session): void {
  if (session.role === 'anon' || !session.id) return;
  // No email anywhere in this auth system by design — passkeys only, no
  // typed identity at all (scripts/serve/auth/walkin.py: "no name, no email,
  // nothing typed: the only identity is the credential") — so that argument
  // is omitted rather than padded with an empty string.
  ineum('user', session.id, session.name || undefined);
}

/**
 * Tag the CURRENT station onto Instana's session meta — the browser-beacon
 * half of the "groupable per station type" ask (analytics/stationAttrs.ts).
 *
 * WHY META AND NOT A PER-CALL TAG. Instana's ajax/XHR auto-instrumentation
 * (what actually beacons the golden-reset POST, the wakeup signalling fetch,
 * etc — this app's OWN spans go to `/traces`, never to Instana) has no
 * documented way to attach a custom attribute to one specific request.
 * `meta` is SESSION-scoped and travels on every beacon sent after it is set,
 * which is exactly the shape wanted here: call this when a station opens (or
 * changes), and every ajax beacon for THAT visit — including a restore click
 * — carries the currently-open station's type until the next call updates it
 * or the tab closes.
 *
 * SAME KEYS AS `stationAttrs()`, minus `kh.station.id` — Instana's own
 * `meta` already has a per-visit identity via `kh.sessionId`; repeating the
 * station id here would not change what a query can group by (both are
 * still per-request meta, and `kh.station.id` is already redundant with
 * whichever station the visitor is looking at when Instana's own Websites
 * view shows the beacon). Each dimension is its own `ineum('meta', k, v)`
 * call — the shape `instana.test.ts` pins, never an object.
 */
export function tagInstanaStation(attrs: { [key: string]: string | number | boolean }): void {
  for (const key of ['kh.station.emulatorFamily', 'kh.station.ui', 'kh.station.resetMode']) {
    const value = attrs[key];
    if (value !== undefined) ineum('meta', key, String(value));
  }
}

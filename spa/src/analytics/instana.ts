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

import { BUNDLE_MARKER } from '../three/clientDebug';
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
export const IGNORE_URL_PATTERNS: RegExp[] = [
  /^\/traces\b/,
  /^\/analytics\b/,
  /^\/coverage\b/,
  /^\/clientlog\b/,
  /^\/usage\b/,
  /^\/clientcmd\b/,
];

/**
 * Everything that does not depend on WHO the visitor is, plus the
 * pseudonymous identity every beacon must carry from the first moment
 * Instana is configured. Call this ONCE, as early as the session id exists,
 * gated by the SAME `allowed` answer `initAnalytics` uses (main.tsx) — an
 * unconfigured build or a signed-out stranger at the walk-in door must get
 * none of this.
 */
export function configureInstana(sessionId: string): void {
  ineum('trackSessions');
  // autoPageDetection: the Instana docs contradict themselves on the default
  // (one page says SPAs get it automatically, another says it is off unless
  // asked for), so it is set explicitly rather than trusted to either claim.
  // This app has real client-side routes (BrowserRouter in main.tsx) with no
  // full navigation between them — without this, every route after the first
  // load is invisible to Instana.
  ineum('autoPageDetection', true);
  // Required for backend correlation: without it the agent never attaches its
  // own W3C trace-context header to outgoing requests, and an Instana trace
  // can never be linked to a backend span at all.
  ineum('enableW3CHeaders', true);
  // Both default OFF. They patch addEventListener/setTimeout/setInterval so
  // an exception thrown from inside a DOM handler or a timer callback is
  // still caught and reported. Without them Instana only sees errors that
  // reach window.onerror directly, which misses a large share of what
  // actually breaks in a WebGL/RAF/pointer-driven app like this one.
  ineum('wrapEventHandlers', true);
  ineum('wrapTimers', true);
  ineum('secrets', SECRET_PATTERNS);
  ineum('ignoreUrls', IGNORE_URL_PATTERNS);
  // THE JOIN — the point of the whole exercise. `kh.sessionId` is the same
  // value clientDebug.ts stamps on every /clientlog event and
  // analytics/trace.ts stamps as `session.id` on every OTel span this tab
  // sends to /traces, so an operator holding an Instana beacon can look up
  // this key and pull the matching kernel-hive trace from
  // /admin/observability, and vice versa. `kh.bundle` is the closest thing
  // this build has to a commit id (three/clientDebug.ts's BUNDLE_MARKER,
  // already used to stamp WHICH client build produced a debug snapshot).
  ineum('meta', { 'kh.sessionId': sessionId, 'kh.bundle': BUNDLE_MARKER });
  // Pseudonymous identity, set FIRST and unconditionally — this is the ONLY
  // identity a signed-out or anonymous visitor ever gets, and it is also
  // what covers the gap before a real account is known: `loadSession()` in
  // main.tsx is an async fetch, and the browser's automatic page-load beacon
  // can fire before that fetch resolves (this is a 3D gallery with real asset
  // weight; the auth round trip does not get to assume it wins the race).
  // Instana does not retroactively correct a beacon already sent — a call
  // made later only affects what goes out AFTER it runs — so setting SOME
  // identity here, synchronously, is what keeps that early beacon from
  // going out with no identity at all. See configureInstanaIdentity for the
  // update once (if) a real account is known.
  ineum('user', sessionId);
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

// ============================================================================
//  analytics/khFetch — automatic outbound propagation, owned by us.
//  ---------------------------------------------------------------------------
//  THE PROBLEM THIS FIXES. `traceHeaders()` (trace.ts) has existed since the
//  tracer landed, and of 24 fetch call sites in this app only TWO ever call
//  it — both of them our own telemetry posts (index.ts, sink.ts). Every
//  user-facing API call — the manifest, signalling, restore, walk-in auth,
//  the fleet table — carries no trace context at all. That is not 22 bugs,
//  it is one: propagation was OPT-IN PER CALL SITE, so it silently rotted the
//  moment nobody was watching. A `khFetch()` helper call sites have to
//  remember to use would fix the two sites that already remember and leave
//  the other 22 exactly where they are.
//
//  THE DECISION: PATCH window.fetch, GLOBALLY, ONCE. Not a wrapper function.
//  The alternative — export `khFetch()` and migrate 24 call sites to it — was
//  rejected on the evidence above: it is the SAME mechanism (opt-in) that
//  produced 22/24 in the first place, just with a better name. A global
//  patch is the one mechanism that reaches every existing call site AND every
//  call site not yet written, with no ongoing discipline required. The costs
//  are real and accepted: it is invasive (nothing marks a fetch call as
//  "instrumented" at the call site), and it can race a THIRD PARTY's own
//  fetch patch — see the Instana section below, which is exactly that race,
//  worked out empirically rather than assumed.
//
//  SAME-ORIGIN ONLY. `url.origin === window.location.origin`, checked before
//  anything else. A trace id is not a secret, but it is a correlation handle
//  for THIS box's own telemetry store, and it has no business leaving it —
//  same principle as instana.ts's SECRET_PATTERNS scrubbing `traceparent` out
//  of what Instana itself is allowed to see in a URL.
//
//  NEVER THE QUERY STRING. `url.pathname`, never `url.search` — the same rule
//  errors.ts states for its fingerprint ("never the stack, never the url")
//  and trace.ts's own header comment: a query string can carry a station id,
//  a ticket-shaped value, or worse, and a span attribute is exactly the kind
//  of place that leaks into an admin UI (`/admin/observability`) that a
//  fingerprint's whole point is to stay out of.
//
//  NEVER A SPAN FOR OUR OWN TELEMETRY POSTS. Reuses
//  `instana.ts`'s `IGNORE_URL_PATTERNS` rather than declaring a second list —
//  that module's own header explains why a second list drifts from the
//  first, and the paths are the same paths (/traces, /analytics, /coverage,
//  /clientlog, /usage, /clientcmd) regardless of which plane is asking. The
//  header (propagation) still goes out to those endpoints — two of them
//  already set it by hand (index.ts, sink.ts) precisely so the SERVER's trace
//  of a `/traces` POST joins the browser trace that produced it; only the
//  CLIENT-SIDE span is skipped, because a span about sending a span is the
//  feedback loop both plane budgets (128 beacons/10s) exist to prevent.
//
//  NEVER BREAKS THE REQUEST. Every enhancement — the header, the span — is
//  computed inside its own try/catch and falls back to calling the ORIGINAL
//  fetch unmodified. "A gallery that loads beats a gallery that measures"
//  (index.ts) applies here more than anywhere: this patch sits in front of
//  every network call the app makes, so a bug in it is not a missing metric,
//  it is a broken gallery.
//
//  THE INSTANA COLLISION, MEASURED NOT GUESSED. Both this patch and Instana's
//  agent (instana.ts, `enableW3CHeaders: true`) want to own the outbound
//  `traceparent` header, and reasoning from Instana's minified source alone
//  is exactly the trap TRACE-CONTEXT.md §4 already fell into once ("asserted
//  nowhere IBM or Instana publishes"). So this was run, not read: the real
//  agent (`registry/local.env`'s pinned `https://eum.instana.io/eum.min.js`)
//  was loaded into a scripted harness with a capturing `fetch` underneath, in
//  both install orders. Findings:
//
//    * Instana's fetch patch uses `Headers.append`, never `.set`, for every
//      header it adds, `traceparent` included — it is written to coexist with
//      an existing value, not overwrite it.
//    * A monkey-patch chain is LAST-INSTALLED-OUTERMOST: whichever patch runs
//      MORE RECENTLY wraps the other and executes FIRST, calling inward
//      toward whichever patched EARLIER, which sits closer to the real
//      network call and therefore has the LAST WORD.
//    * So: if THIS patch installs before Instana's agent has loaded (the
//      common case — this module is imported synchronously at the top of
//      main.tsx; Instana's agent is a separately-fetched, non-parser-inserted
//      `<script>` and therefore genuinely async per the HTML spec, `defer`
//      notwithstanding, per spa/index.html's own comment on that tag), THIS
//      patch ends up innermost. Instana's outer wrapper appends its headers
//      first; this patch then runs `Headers.set('traceparent', ours)`
//      afterward and OVERWRITES whatever Instana put there — verified: the
//      wire header is our clean single value, Instana's X-INSTANA-*/
//      tracestate headers are untouched beside it.
//    * If the order is reversed — Instana's agent finishes loading and
//      patches first — this patch becomes OUTER, sets the header first, and
//      Instana's INNER `.append` then turns it into
//      `"<ours>, 00-...-03"` — two comma-joined values in one header. That is
//      not a valid single `traceparent` (§1), so both this box's parser
//      (`scripts/serve/tracecontext.py`) and Instana's own backend treat it
//      as malformed and start a fresh trace for that one call — exactly the
//      "malformed → new trace, never refuse the work" rule TRACE-CONTEXT.md
//      §1 already states. The request itself is never broken either way.
//    * So the two orders differ only in whether ONE call's join survives, not
//      in whether anything breaks. This module is installed as the very
//      first import evaluated by main.tsx specifically to bias toward the
//      winning order, but does not chase a hard guarantee (e.g. an inline
//      `<script>` ahead of Instana's own bootstrap in index.html) — that
//      would mean re-implementing trace-id minting and span buffering
//      outside this module in raw HTML-inline JS, a second implementation of
//      exactly the kind this module exists to stop having. A best-effort win
//      that degrades to "no join, still no breakage" was judged the better
//      trade.
// ============================================================================

import { IGNORE_URL_PATTERNS } from './instana';
import { childOfActive, traceHeaders } from './trace';

let installed = false;

/** For tests. */
export function __resetKhFetch(): void {
  installed = false;
}

function isExcludedPath(path: string): boolean {
  return IGNORE_URL_PATTERNS.some((re) => re.test(path));
}

/** The `traceparent` value already on an outbound request, if the caller set
 *  one deliberately — respected rather than overwritten, so a call site that
 *  wants to propagate a SPECIFIC id (a retry continuing the same attempt,
 *  say) is never second-guessed by the global patch. */
function existingTraceparent(input: RequestInfo | URL, init: RequestInit | undefined): string | null {
  const fromInit = init?.headers;
  if (fromInit instanceof Headers) return fromInit.get('traceparent');
  if (Array.isArray(fromInit)) {
    const hit = fromInit.find(([k]) => k.toLowerCase() === 'traceparent');
    return hit ? hit[1] : null;
  }
  if (fromInit && typeof fromInit === 'object') {
    const rec = fromInit as Record<string, string>;
    return rec.traceparent ?? rec.Traceparent ?? null;
  }
  if (input instanceof Request) return input.headers.get('traceparent');
  return null;
}

function withTraceparent(init: RequestInit | undefined, input: RequestInfo | URL, value: string): RequestInit {
  const headers = new Headers(init?.headers ?? (input instanceof Request ? input.headers : undefined));
  headers.set('traceparent', value);
  return { ...(init ?? {}), headers };
}

function requestMethod(input: RequestInfo | URL, init: RequestInit | undefined): string {
  const m = init?.method ?? (input instanceof Request ? input.method : undefined);
  return (m ?? 'GET').toUpperCase();
}

/** Resolve `input` to an absolute URL against the current page, same-origin
 *  test included. Never throws: an unparseable input is treated as not ours
 *  to touch, and falls through to the original fetch untouched. */
function resolveSameOrigin(input: RequestInfo | URL): URL | null {
  try {
    const raw = input instanceof Request ? input.url : String(input);
    const url = new URL(raw, window.location.href);
    return url.origin === window.location.origin ? url : null;
  } catch {
    return null;
  }
}

function tracedFetch(
  original: typeof fetch,
  input: RequestInfo | URL,
  init: RequestInit | undefined,
): ReturnType<typeof fetch> {
  const url = resolveSameOrigin(input);
  if (!url) return original(input, init);

  const path = url.pathname; // NEVER url.search — see module header.
  const method = requestMethod(input, init);
  let finalInit = init;
  try {
    if (!existingTraceparent(input, init)) {
      const { traceparent } = traceHeaders();
      if (traceparent) finalInit = withTraceparent(init, input, traceparent);
    }
  } catch {
    finalInit = init; // the request still goes out, just unpropagated
  }

  if (isExcludedPath(path)) return original(input, finalInit);

  let span: ReturnType<typeof childOfActive> | null;
  try {
    span = childOfActive(`HTTP ${method}`, { 'http.request.method': method, 'url.path': path }, 'client');
  } catch {
    span = null;
  }
  if (!span) return original(input, finalInit);

  const liveSpan = span;
  return original(input, finalInit).then(
    (res) => {
      try {
        liveSpan.end(res.ok ? 'ok' : 'error', { 'http.response.status_code': res.status });
      } catch { /* the response is still handed back regardless */ }
      return res;
    },
    (err: unknown) => {
      try {
        liveSpan.recordException(err);
        liveSpan.end('error');
      } catch { /* rethrow proceeds either way */ }
      throw err;
    },
  );
}

/**
 * Patch `window.fetch` once, so every same-origin request this app makes —
 * present call sites and future ones alike — carries `traceparent` and opens
 * a client span, with no call site having to remember either. Safe to call
 * more than once (idempotent) and safe in a non-browser environment (SSR,
 * tests) where it is simply a no-op. See the module header for the mechanism
 * decision and the Instana race.
 */
export function installKhFetchPropagation(): void {
  try {
    if (installed) return;
    if (typeof window === 'undefined' || typeof window.fetch !== 'function') return;
    const current = window.fetch as typeof fetch & { __khPatched?: boolean };
    if (current.__khPatched) {
      installed = true;
      return;
    }
    const original = current.bind(window);
    const patched = ((input: RequestInfo | URL, init?: RequestInit) => {
      try {
        return tracedFetch(original, input, init);
      } catch {
        return original(input, init);
      }
    }) as typeof fetch & { __khPatched?: boolean };
    patched.__khPatched = true;
    window.fetch = patched;
    installed = true;
  } catch {
    /* a gallery that loads beats a gallery that measures */
  }
}

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
//  THE HEADER NAMES THIS CALL'S OWN SPAN, AND THE ORDER ENFORCES IT. The
//  client span is created BEFORE the header is built, and the header is built
//  from that span's ids. Until 2026-09-01 it was the other way round —
//  `traceHeaders()` first, span afterwards — which meant the outgoing
//  `traceparent` never named the client span, because `traceHeaders()` reads
//  `currentSpan()` and `childOfActive()` does not push. Two failures, neither
//  visible from inside this file: inside an open flow the server's entry span
//  was parented on the FLOW ROOT and came out a SIBLING of
//  `http.client.request` (the RPC edge simply absent from the flame graph);
//  with no active span, the header carried a freshly minted trace id owned by
//  no span at all while the client span carried a different one — two
//  unrelated traces per call. The fix is here and not in the active-span model
//  on purpose: making `childOfActive()` push would put a span that lives
//  across an `await` on a synchronous LIFO stack with no async context, and
//  every span opened by unrelated code during the request would be re-parented
//  under a fetch. `trace.ts`'s `traceparentOf()` carries the same note.
//
//  THE RETURN LEG. A traced response names its own server span back to us:
//  `traceresponse` (W3C Trace Context Level 2 — ours) preferred, falling back
//  to `Server-Timing: intid;desc=<trace-id>` (the token Instana's EUM agent
//  parses — the vendor bridge). The id lands on the client span as
//  `kh.backend.trace_id`, which is what lets /admin/observability jump from a
//  click to the server trace with no vendor in the loop, and is mirrored to
//  Instana as a `backendTraceId` because doing so is one call and free.
//  Same-origin only, so no `Access-Control-Expose-Headers` question arises.
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

import { IGNORE_URL_PATTERNS, reportBackendTrace } from './instana';
import { childOfActive, traceHeaders, traceparentOf, type Span } from './trace';

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

/** The backend trace id this response advertises, or null.
 *
 *  TWO readers, ONE preference order, both same-origin only (no
 *  `Access-Control-Expose-Headers` anywhere: a cross-origin response is never
 *  read here because a cross-origin request never gets this far — see
 *  `resolveSameOrigin`):
 *
 *   * `traceresponse` — W3C Trace Context Level 2's response header, and OUR
 *     plane's mechanism. Preferred because it carries the SPAN id as well as
 *     the trace id, and because it is a standard rather than a vendor's
 *     parsing convention.
 *   * `Server-Timing: intid;desc=<trace-id>` — the same trace id, in the token
 *     Instana's EUM agent parses. Read as a fallback so a response from a
 *     layer that emits only the vendor bridge still correlates.
 *
 *  Returns the TRACE id in both cases: that is the handle
 *  `/admin/observability` opens a trace by, and the only shape Instana accepts
 *  as a `backendTraceId`. */
function backendTraceIdOf(res: Response): string | null {
  try {
    const tr = res.headers.get('traceresponse');
    if (tr) {
      const parts = tr.trim().split('-');
      if (parts.length === 4 && /^[0-9a-f]{32}$/.test(parts[1])) return parts[1];
    }
    const timing = res.headers.get('server-timing');
    if (timing) {
      const hit = /(?:^|,)\s*intid\s*;\s*desc\s*=\s*"?([0-9a-f]{32})"?/i.exec(timing);
      if (hit) return hit[1].toLowerCase();
    }
  } catch { /* a header we cannot read is a header we do not have */ }
  return null;
}

/** Record the server's trace id on OUR client span, and mirror it to the
 *  vendor. The attribute is what makes the jump work in our own UI — Instana
 *  is the free side effect, not the mechanism.
 *
 *  `kh.backend.trace_id` is 20 characters and its value 32, so it survives
 *  `scripts/serve/traces.py`'s intake unaltered (key ≤ 64, not in
 *  `BANNED_ATTRS`, value ≤ `ATTR_STR_MAX` = 120) — an attribute the store
 *  silently truncated would be worse than none, because it would look right in
 *  the tab and be un-joinable in the store. */
function recordBackendTrace(span: Span, res: Response, path: string): void {
  const backend = backendTraceIdOf(res);
  if (!backend) return;
  span.attr('kh.backend.trace_id', backend);
  reportBackendTrace('kh.http.backend', backend, { 'url.path': path });
}

/** The header value to send, and the ONE rule about where it comes from.
 *
 *  It must name the span we just opened, so the server's entry span becomes
 *  that span's CHILD — the RPC edge. `traceHeaders()` cannot answer this: it
 *  reads `currentSpan()`, which is never the client span (`childOfActive()`
 *  does not push, deliberately — `trace.ts`'s `traceparentOf` says why), so
 *  inside an open flow it named the FLOW ROOT (making the server span a
 *  SIBLING of `http.client.request`, edge missing) and outside one it minted a
 *  fresh trace id belonging to no span at all (client span and server span in
 *  two unrelated traces). It is still the right answer for a request with no
 *  span of its own — the telemetry-path exclusions below — which is exactly
 *  the split this function encodes. */
function outboundTraceparent(span: Span | null): string | null {
  const own = traceparentOf(span);
  if (own) return own;
  return traceHeaders().traceparent ?? null;
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
  const excluded = isExcludedPath(path);

  // SPAN FIRST, HEADER SECOND. The order is the whole point: the header has to
  // name the span, so the span has to exist. An excluded telemetry path opens
  // no span and still propagates, from the active span, exactly as before.
  let span: Span | null = null;
  try {
    // DEFECT 5 FIX. This used to be named `` `HTTP ${method}` `` — e.g.
    // "HTTP GET" — which is exactly what every unit test in this file still
    // asserts happily, because nothing here talks to the SERVER's ingest
    // validator. `scripts/serve/traces.py`'s NAME_RE is
    // `^[A-Za-z][A-Za-z0-9._-]{0,79}$` — no space, ever — so the store
    // silently `continue`s past every span this patch ever produced: the
    // header propagates (verified — `serve.auth.walkin.status` shows up
    // inside a `serve.page` trace), the request completes, the span is built
    // and buffered and POSTed, and the server drops it with no error back to
    // the tab. 30 minutes of live traffic, 791 API calls, zero client spans
    // in the store — this is why. Fixed name, method as an attribute
    // (already carried in `http.request.method` below) rather than in the
    // name, so the name satisfies NAME_RE regardless of verb.
    if (!excluded) {
      span = childOfActive('http.client.request', { 'http.request.method': method, 'url.path': path }, 'client');
    }
  } catch {
    span = null;
  }

  let finalInit = init;
  try {
    if (!existingTraceparent(input, init)) {
      const traceparent = outboundTraceparent(span);
      if (traceparent) finalInit = withTraceparent(init, input, traceparent);
    }
  } catch {
    finalInit = init; // the request still goes out, just unpropagated
  }

  if (!span) return original(input, finalInit);

  const liveSpan = span;
  return original(input, finalInit).then(
    (res) => {
      try {
        recordBackendTrace(liveSpan, res, path);
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

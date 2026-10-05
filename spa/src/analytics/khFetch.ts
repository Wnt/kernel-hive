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
//  "instrumented" at the call site), and any other script that patches fetch
//  chains with it: monkey-patches are last-installed-outermost, so whichever
//  patch installed EARLIER sits closer to the network and has the last word
//  on a header both of them set.
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
//  THE RETURN LEG. A traced response names its own server span back to us in
//  `traceresponse` (W3C Trace Context Level 2). The id lands on the client
//  span as `kh.backend.trace_id`, which is what lets /admin/observability jump
//  from a click to the server trace. Same-origin only, so no
//  `Access-Control-Expose-Headers` question arises.
//
//  SAME-ORIGIN ONLY. `url.origin === window.location.origin`, checked before
//  anything else. A trace id is not a secret, but it is a correlation handle
//  for THIS box's own telemetry store, and it has no business leaving it.
//
//  NEVER THE QUERY STRING. `url.pathname`, never `url.search` — the same rule
//  errors.ts states for its fingerprint ("never the stack, never the url")
//  and trace.ts's own header comment: a query string can carry a station id,
//  a ticket-shaped value, or worse, and a span attribute is exactly the kind
//  of place that leaks into an admin UI (`/admin/observability`) that a
//  fingerprint's whole point is to stay out of.
//
//  NEVER A SPAN FOR OUR OWN TELEMETRY POSTS. The paths come from
//  `telemetryPaths.ts`'s `IGNORE_URL_PATTERNS` — one list, mirrored and pinned
//  on the server side, never a second hand-kept copy here. A span about
//  sending a span is a feedback loop: every upload would manufacture the next.
//
//  AND NO HEADER EITHER, as of 2026-09-01. Those paths used to propagate from
//  the ambient span anyway, which named a parent we had already decided not to
//  record — the serving plane traces four of the six — and left every
//  `serve.clientcmd`/`serve.clientlog`/`serve.analytics`/`serve.usage` entry
//  span permanently rootless. No span, no header, and the server roots its own
//  trace: see `outboundTraceparent` for the whole argument, including why the
//  server span is kept rather than suppressed with an unsampled flag.
//
//  NEVER BREAKS THE REQUEST. Every enhancement — the header, the span — is
//  computed inside its own try/catch and falls back to calling the ORIGINAL
//  fetch unmodified. "A gallery that loads beats a gallery that measures"
//  (index.ts) applies here more than anywhere: this patch sits in front of
//  every network call the app makes, so a bug in it is not a missing metric,
//  it is a broken gallery.
// ============================================================================

import { IGNORE_URL_PATTERNS } from './telemetryPaths';
import { childOfActive, traceparentOf, type Span } from './trace';

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

/** The backend trace id this response advertises in `traceresponse` (W3C
 *  Trace Context Level 2's response header), or null. Same-origin only — no
 *  `Access-Control-Expose-Headers` anywhere: a cross-origin response is never
 *  read here because a cross-origin request never gets this far (see
 *  `resolveSameOrigin`).
 *
 *  Returns the TRACE id: that is the handle `/admin/observability` opens a
 *  trace by. */
function backendTraceIdOf(res: Response): string | null {
  try {
    const tr = res.headers.get('traceresponse');
    if (tr) {
      const parts = tr.trim().split('-');
      if (parts.length === 4 && /^[0-9a-f]{32}$/.test(parts[1])) return parts[1];
    }
  } catch { /* a header we cannot read is a header we do not have */ }
  return null;
}

/** Record the server's trace id on OUR client span — the attribute is what
 *  makes the click-to-server-trace jump work in /admin/observability.
 *
 *  `kh.backend.trace_id` is 20 characters and its value 32, so it survives
 *  `scripts/serve/traces.py`'s intake unaltered (key ≤ 64, not refused as a
 *  credential, value ≤ `ATTR_STR_MAX` = 2048) — an attribute the store
 *  silently truncated would be worse than none, because it would look right in
 *  the tab and be un-joinable in the store. */
function recordBackendTrace(span: Span, res: Response): void {
  const backend = backendTraceIdOf(res);
  if (!backend) return;
  span.attr('kh.backend.trace_id', backend);
}

/** The header value to send, and the ONE rule about where it comes from:
 *  IT NAMES THE SPAN WE JUST OPENED, OR THERE IS NO HEADER.
 *
 *  Nothing else will do, and both alternatives have now been tried and
 *  measured on the live store. `traceHeaders()` — read `currentSpan()` — was
 *  the original, and it named the FLOW ROOT inside a flow (the server span
 *  came out a SIBLING of `http.client.request`, the RPC edge simply absent)
 *  and minted a fresh trace id owned by no span outside one. It was fixed for
 *  the span-bearing case in 64769b75 and left as a FALLBACK here, which kept
 *  the second half of the bug alive in two places:
 *
 *    * an EXCLUDED TELEMETRY PATH opens no span deliberately (a span about
 *      sending a span is a feedback loop), and the fallback still propagated
 *      for it — so
 *      `serve.clientcmd` was parented on an id we had already decided never
 *      to record;
 *    * a NON-EXCLUDED path whose span came back NOOP — `MAX_OPEN` exhausted,
 *      or the tracer off for a signed-out tab — fell through to the same
 *      fallback, which is how one seven-hour tab pointed 6,678 polls at a
 *      single flow-root id that was never written.
 *
 *  So the fallback is gone. `null` means the request goes out with no
 *  `traceparent` and the serving plane cleanly ROOTS ITS OWN TRACE — a
 *  one-span `serve.clientcmd` trace that is complete and readable, instead of
 *  a child of a parent that will never arrive. The server span is deliberately
 *  NOT suppressed (which sending `-00` would do, via `tracing_http.begin`'s
 *  unsampled-parent NOOP): its latency and status are the only record that
 *  route has, and losing them to fix a parent id would be a worse trade than
 *  the bug. */
function outboundTraceparent(span: Span | null): string | null {
  return traceparentOf(span);
}

/** The attributes an exit span owes, in CURRENT OpenTelemetry HTTP semantic
 *  convention names — `http.request.method`, `url.path`, `url.scheme`,
 *  `server.address`, `server.port`. The stable conventions only; no
 *  previous-generation spelling is emitted from the tab.
 *
 *  STILL NEVER THE QUERY STRING. `url.pathname` only, and the three parts added
 *  here are a scheme, a host and a port — none of which can carry one, so
 *  nothing here reintroduces what `traces.py`'s BANNED_ATTRS exists to keep
 *  out.
 *
 *  `server.port` is the EFFECTIVE port: `URL.port` is empty for the scheme's
 *  default, and a consumer reading "no port" cannot tell that from "port not
 *  recorded". */
function clientAttrs(method: string, url: URL): Record<string, string | number> {
  const scheme = url.protocol.replace(/:$/, '');
  return {
    'http.request.method': method,
    'url.path': url.pathname,
    'url.scheme': scheme,
    'server.address': url.hostname,
    'server.port': Number(url.port) || (scheme === 'https' ? 443 : 80),
  };
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
      span = childOfActive('http.client.request', clientAttrs(method, url), 'client');
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
        recordBackendTrace(liveSpan, res);
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
 * decision.
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

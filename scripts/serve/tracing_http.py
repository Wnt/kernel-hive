"""The request path's half of the tracer: which routes get a span, and the
wrapper that opens and closes it.

`tracing.py` is the tracer; this is where it meets `BaseHTTPRequestHandler`.
It exists as its own module for the reason `telemetry_routes.py` does:
`osgallery-https-server.py` sits on the repo's 600-line hard cap, so the two
lines it can afford are an import and a call.

STATIC ASSET SERVING IS DELIBERATELY NOT TRACED, and that is the single most
important decision in this file. It is the highest-volume path in the server by
an order of magnitude — a station page pulls a dozen hashed assets and the grid
sixty poster thumbnails — its volume is already in the access log, and a span
per PNG would bury every span anybody actually wants under thousands nobody
does. So routing is an ALLOWLIST: `route_of()` returns None for anything it does
not recognise, and a path that is not recognised is not traced at all. Static
files, the SPA fallback and every route added later are excluded BY
CONSTRUCTION, rather than by a deny-list somebody has to remember to extend.

Three more paths are named and refused below for reasons of their own:
`/healthz` (a liveness poll whose answer is a constant), and `POST /traces` and
`POST /coverage` (the telemetry INGEST — a span describing the delivery of spans
lands inside the very trace it is delivering, where it reads as work the
visitor's journey did).

THE RETURN LEG. A traced response carries its own span back to the caller in
two headers, written at one choke point (`end_headers`, wrapped below) so that
every reply shape the stdlib can produce — 200, 304, 206, 416, HEAD, an error
page, a streamed body — gets them without any handler knowing they exist:

  * `traceresponse: 00-<trace-id>-<span-id>-01` — W3C Trace Context Level 2's
    response header, the mirror of the inbound `traceparent`. This is OUR
    plane's mechanism: the browser reads it in `khFetch.ts` and records the id
    on its client span, so `/admin/observability` can walk from a click to the
    server trace with no vendor in the loop.
  * `Server-Timing: intid;desc=<trace-id>` — the vendor bridge. Instana's EUM
    agent parses exactly this token and sets it as the beacon's
    `backendTraceId`. It is emitted because it is free, not because anything
    here depends on it.

Both come from `tracecontext.response_headers()`, which returns `{}` for a
NOOP span, so an UNTRACED route emits neither header, by construction rather
than by a second copy of the allowlist.

THE ROUTE, NOT THE PATH. `http.route` is a low-cardinality TEMPLATE
(`/signal/{station}.json`), which is what the OTel convention means by it and
what keeps `traces.facets()` usable. The concrete station goes in `kh.station`,
which is an exhibit id and public in the gallery manifest. Nothing else off the
request line is recorded here yet: no query string, no body, no header but Host.
That is this module's current scope, not a prohibition — `url.query` and
`url.full` stopped being refused at intake on 2026-09-01 (docs/ANALYTICS.md §0),
so recording them is now a decision this file may take. A token never goes in a
span whatever else does: `traces.SECRET_KEY_RE` refuses one at intake by shape.
"""

from __future__ import annotations

import contextlib
import functools
from urllib.parse import unquote, urlparse

import tracecontext
import tracing

#: Literal paths worth a span, mapped to nothing: the span name is derived from
#: the path (`/walkin/claim` -> `serve.walkin.claim`), so adding a route here is
#: one line and cannot drift from its name.
_LITERAL = frozenset(
    {
        "/signal/index.json",
        "/usage",
        "/usage/stations.json",
        "/clientlog",
        "/clientcmd",
        "/analytics",
        "/analytics/report.json",
        "/coverage/report.json",
        "/kh/deploy-hint",
        # The walk-in plane. Every one of these is a decision a visitor waits
        # on, and `claim` is the slowest thing this server does.
        "/walkin/state",
        "/walkin/claim",
        "/walkin/release",
        "/walkin/reset",
        "/walkin/manifest.json",
        # The auth ceremonies. A passkey round trip that got slow, or a redeem
        # that keeps failing, is invisible in the access log's 200s.
        "/auth/state",
        "/auth/me",
        "/auth/logout",
        "/auth/login/begin",
        "/auth/login/finish",
        "/auth/redeem/begin",
        "/auth/redeem/finish",
        "/auth/invite/enter",
        "/auth/passkeys/begin",
        "/auth/passkeys/finish",
        "/auth/passkeys/delete",
        "/auth/link/create",
        "/auth/usage/report",
        "/auth/walkin/status",
        "/auth/walkin/access",
        "/auth/walkin/drain",
        "/auth/walkin/purge",
    }
)

#: Paths carrying ONE station id, as (prefix, suffix, template, span name). The
#: id is bounded by the route it was reached under — an unknown one 404s — so it
#: is safe as an attribute and useful as one: "which station is slow" is the
#: question this whole lab asks most often.
_PARAMETERISED = (
    ("/signal/", ".json", "/signal/{station}.json", "serve.signal"),
    ("/restore/", "", "/restore/{station}", "serve.restore"),
    ("/walkin/play/", "", "/walkin/play/{station}", "serve.walkin.play"),
)


def _name_for(path: str) -> str:
    """`/auth/login/begin` -> `serve.auth.login.begin`. Matches traces.NAME_RE."""
    return "serve" + path.replace("/", ".").rstrip(".")


def route_of(path: str):
    """`(http.route, span name, station or None)`, or None when NOT traced.

    The allowlist. Everything the server can answer that is not named here —
    every static file, the SPA fallback, `/healthz`, the telemetry ingest — is
    deliberately invisible to tracing; see the module docstring.
    """
    if path in _LITERAL:
        return path, _name_for(path), None
    if path.startswith("/webrtc/") and path.endswith("/offer"):
        station = path[len("/webrtc/") : -len("/offer")].strip("/")
        return "/webrtc/{station}/offer", "serve.webrtc.offer", station or None
    if path.startswith("/auth/traces/"):
        # One template for the whole admin read surface: the tail carries a
        # trace id, which is high-cardinality and already the thing being read.
        return "/auth/traces/*", "serve.auth.traces", None
    for prefix, suffix, template, name in _PARAMETERISED:
        if not path.startswith(prefix):
            continue
        tail = path[len(prefix) :]
        if suffix:
            if not tail.endswith(suffix):
                continue
            tail = tail[: -len(suffix)]
        tail = tail.strip("/")
        if tail and "/" not in tail:
            return template, name, tail
    return None


def _host(handler) -> str:
    """`server.address`: the authority this request was addressed to, no port."""
    host = (handler.headers.get("Host") or "").strip()
    if host.startswith("["):  # bracketed IPv6 literal
        return host.split("]")[0][1:]
    return host.split(":")[0]


def begin(handler, method: str, path: str) -> tracing.Span:
    """Open the request's root span, or NOOP. Never raises, never fails a request."""
    try:
        matched = route_of(path)
        if matched is None:
            return tracing.NOOP
        template, name, station = matched
        # The inbound parent, and the browser's sampling decision with it
        # (contract §4): unsampled in means nothing out, so this layer can never
        # be the reason a flame graph has a hole in it.
        parent = tracecontext.parse(tracecontext.header_of(handler))
        if parent is not None and not parent.sampled:
            return tracing.NOOP
        if not tracing.is_bound():
            return tracing.NOOP
        attrs = {
            "http.request.method": method,
            "http.route": template,
            "server.address": _host(handler),
            # Which fence this request came through. The same route behaves
            # differently on the two listeners — the LAN one is open and the
            # public one is gated — and a latency or error number that mixed
            # them would be answering two questions at once.
            "kh.listener": "public" if getattr(handler, "public", False) else "lan",
        }
        if station:
            attrs["kh.station"] = station
        trace_id = parent.trace_id if parent is not None else tracing.new_trace_id()
        return tracing.Span(trace_id, parent.span_id if parent else None, name, attrs, "server")
    except Exception:  # noqa: BLE001 - a header may never fail a request
        return tracing.NOOP


def _status_of(handler) -> tuple:
    """`(otel status, http code)` from whatever the handler last replied."""
    code = getattr(handler, "_kh_status", 0)
    if not isinstance(code, int) or code <= 0:
        return "unset", 0
    return ("error" if code >= 500 else "ok"), code


def set_response_trace(handler, span) -> None:
    """Name `span` as the span THIS response reports back — the ONE writer of
    the return-leg headers.

    Nothing else in the serving plane may put `traceresponse` or
    `Server-Timing` on a response. They wait here, on the handler, until
    `end_headers` writes them (see `_wrap_end_headers`), and the last caller
    wins rather than appending — which is what makes "one response, one pair"
    a property of the code rather than of every caller remembering.

    It was NOT a property of the code until 2026-09-01. `static_files.py`
    merged its own copy of the same two headers into the `extra` dict of the
    index.html reply, so a request that BOTH matched the route allowlist AND
    fell through to the SPA fallback emitted two pairs naming two different
    spans. Every `/auth/*` and `/walkin/*` path on the ungated LAN listener is
    exactly that request: `auth_routes.dispatch` runs only when `self.public`,
    so on LAN those paths are answered with index.html. Two writers, no
    arbitration; now one writer, and `extra` cannot carry these at all.

    NOOP (or any span without a well-formed id pair) clears the stash, because
    `tracecontext.response_headers` returns `{}` for one — an untraced response
    says nothing about a trace rather than saying something empty.
    """
    with contextlib.suppress(Exception):  # never fail a response over a header
        handler._kh_trace_response = tracecontext.response_headers(span.trace_id, span.span_id)


def _wrap_verb(fn):
    @functools.wraps(fn)
    def wrapper(self, *a, **kw):
        # ONE REQUEST, ONE SPAN, even if this verb is wrapped more than once.
        # `instrument()` will not wrap an already-wrapped function, but a
        # subclass that overrides `do_GET` and calls `super().do_GET()` puts two
        # DIFFERENT wrapped functions on one call stack, which no wrapping-time
        # check can see. The guard is on the request, so it holds either way.
        try:
            reentrant = bool(getattr(self, "_kh_in_request", False))
            if not reentrant:
                self._kh_in_request = True
        except Exception:  # noqa: BLE001 - a handler we cannot mark is passed through
            reentrant = True
        if reentrant:
            return fn(self, *a, **kw)
        try:
            return _traced_call(self, fn, a, kw)
        finally:
            self._kh_in_request = False

    wrapper._kh_traced_wrapper = True  # after functools.wraps, which copies __dict__
    return wrapper


def _traced_call(self, fn, a, kw):
    """One request, inside the re-entrancy guard `_wrap_verb` just armed."""
    try:
        self._kh_status = 0
        # Per RESPONSE, not per connection: keep-alive reuses the handler
        # instance, so a traced reply must not leak its ids onto the next
        # request's untraced one. This is also the ONLY place the stash is
        # cleared — every response starts with nothing to report.
        self._kh_trace_response = None
        path = unquote(urlparse(self.path).path)
    except Exception:  # noqa: BLE001
        return fn(self, *a, **kw)
    span = begin(self, self.command or fn.__name__[3:], path)
    if span is tracing.NOOP:
        return fn(self, *a, **kw)
    # Stashed for `end_headers` to write, not written here: at this point
    # the handler has not sent a status line yet, and headers may only be
    # emitted between `send_response()` and `end_headers()`.
    set_response_trace(self, span)
    tracing.push(span)
    try:
        return fn(self, *a, **kw)
    except BaseException as exc:
        span.record_exception(exc)
        span.end("error", {"http.response.status_code": _status_of(self)[1] or 500})
        raise
    finally:
        tracing.pop(span)
        status, code = _status_of(self)
        span.end(status, {"http.response.status_code": code} if code else None)


def _wrap_end_headers(fn):
    """Write the response's trace headers, once, immediately before the blank
    line that closes the header block.

    One choke point rather than a call in each handler: every reply the stdlib
    can produce ends here — 200, 304 (no body, headers still legal and still
    useful: the browser learns which trace answered its revalidation), 206,
    416, a HEAD (headers only, by definition), an error page, and the
    long-lived streaming replies, whose headers are written once at the top and
    are exactly as safe to extend as anyone else's.

    Cleared after writing so a keep-alive connection's NEXT response starts
    with nothing stashed, and wrapped in a `try` so a telemetry header can never
    be the reason a response fails to close its header block.
    """

    @functools.wraps(fn)
    def wrapper(self, *a, **kw):
        try:
            headers = getattr(self, "_kh_trace_response", None)
            self._kh_trace_response = None
            for k, v in (headers or {}).items():
                self.send_header(k, v)
        except Exception:  # noqa: BLE001 - never fail a response over a header
            pass
        return fn(self, *a, **kw)

    wrapper._kh_traced_wrapper = True
    return wrapper


def _wrap_send_response(fn):
    @functools.wraps(fn)
    def wrapper(self, code, *a, **kw):
        self._kh_status = code
        return fn(self, code, *a, **kw)

    wrapper._kh_traced_wrapper = True
    return wrapper


#: Which method gets which wrapper. One table so `instrument()` is a loop with
#: no special cases, and so "what does instrumentation touch?" has one answer.
_WRAPPERS = {
    "do_GET": _wrap_verb,
    "do_POST": _wrap_verb,
    "send_response": _wrap_send_response,
    "end_headers": _wrap_end_headers,
}


def instrument(handler_cls):
    """Give one handler class request spans. Idempotent, at any depth.

    Wrapping `do_GET`/`do_POST` rather than editing them keeps the whole of this
    out of `osgallery-https-server.py`, which is five lines under the file-size
    hard cap. `send_response` is wrapped too, purely to learn the status code:
    the stdlib records it only in the log line. `end_headers` is wrapped to write
    the return-leg headers (module docstring) at the one point every response
    shape passes through.

    IDEMPOTENCE IS PER METHOD, NOT PER CLASS, and that distinction is the whole
    point. A class-level "already done" flag lives in ONE class's `__dict__`, so
    instrumenting a base and then a subclass wrapped every inherited method a
    second time — two spans, in two unrelated traces, for one request — while
    still refusing to wrap a subclass's own overriding `do_GET`, which is the
    one case a subclass call actually needs. Marking the WRAPPER FUNCTION gets
    both right: an inherited wrapper is recognised through any number of
    subclasses, and a genuinely new override is wrapped. The remaining case no
    wrapping-time check can see — an override that calls `super()` into another
    wrapper — is caught at request time by `_wrap_verb`'s re-entrancy guard.

    NOTHING HERE IS SWALLOWED. This runs once, at import, wiring a server that
    has not yet accepted a connection; "never fail a request over telemetry"
    (docs/lab/TRACE-CONTEXT.md §7) is a rule about the REQUEST path, and the
    per-request wrappers keep their own guards. A blanket `except Exception:
    pass` here bought nothing and cost the ability to see a wiring mistake:
    a half-instrumented handler serves perfectly well and reports nothing,
    which is exactly the failure that hides longest.
    """
    for name, wrap in _WRAPPERS.items():
        fn = getattr(handler_cls, name, None)
        if fn is None or getattr(fn, "_kh_traced_wrapper", False):
            continue
        setattr(handler_cls, name, wrap(fn))
    handler_cls._kh_status = 0
    handler_cls._kh_trace_response = None
    handler_cls._kh_in_request = False
    return handler_cls


def install(handler_cls, store) -> None:
    """Wire the tracer to its store AND instrument the handler, in one call.

    One entry point rather than two because the caller is
    `osgallery-https-server.py`, which is five lines under the file-size hard
    cap; splitting this in two would have cost one of them for no gain.
    Instrumenting the base class covers `PublicH`, which inherits both verbs.
    """
    tracing.bind(store)
    instrument(handler_cls)

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

THE ROUTE, NOT THE PATH. `http.route` is a low-cardinality TEMPLATE
(`/signal/{station}.json`), which is what the OTel convention means by it and
what keeps `traces.facets()` usable. The concrete station goes in `kh.station`,
which is an exhibit id and public in the gallery manifest. Nothing else off the
request line is recorded: no query string, no body, no header but Host, and
never a token — `url.query` and `url.full` are in `traces.BANNED_ATTRS` anyway.
"""

from __future__ import annotations

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


def _wrap_verb(fn):
    @functools.wraps(fn)
    def wrapper(self, *a, **kw):
        try:
            self._kh_status = 0
            path = unquote(urlparse(self.path).path)
        except Exception:  # noqa: BLE001
            return fn(self, *a, **kw)
        span = begin(self, self.command or fn.__name__[3:], path)
        if span is tracing.NOOP:
            return fn(self, *a, **kw)
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

    return wrapper


def _wrap_send_response(fn):
    @functools.wraps(fn)
    def wrapper(self, code, *a, **kw):
        self._kh_status = code
        return fn(self, code, *a, **kw)

    return wrapper


def instrument(handler_cls):
    """Give one handler class request spans. Idempotent; safe on a subclass.

    Wrapping `do_GET`/`do_POST` rather than editing them keeps the whole of this
    out of `osgallery-https-server.py`, which is five lines under the file-size
    hard cap. `send_response` is wrapped too, purely to learn the status code:
    the stdlib records it only in the log line.
    """
    try:
        if handler_cls.__dict__.get("_kh_traced"):
            return handler_cls
        handler_cls._kh_traced = True
        handler_cls._kh_status = 0
        for verb in ("do_GET", "do_POST"):
            fn = getattr(handler_cls, verb, None)
            if fn is not None:
                setattr(handler_cls, verb, _wrap_verb(fn))
        handler_cls.send_response = _wrap_send_response(handler_cls.send_response)
    except Exception:  # noqa: BLE001 - an uninstrumented server still serves
        pass
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

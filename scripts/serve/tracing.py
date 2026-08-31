"""In-process OpenTelemetry TRACING for the serving plane.

The contract is docs/lab/TRACE-CONTEXT.md; this module is the Python layer's
half of it. `probes.py` answers "was this branch ever taken"; this answers "what
did ONE request do, and where did its time go" — and, because the browser sends
`traceparent` and this module honours it, it answers that in the same picture as
the tab's own spans.

FOUR PROPERTIES THE REQUEST PATH DEPENDS ON. They are the reason this file is
longer than the instrumentation it enables, and each has a test.

  1. NOTHING HERE RAISES INTO A HANDLER. Every public entry point is wrapped.
     `test_tracing.py` binds a store that raises on every call and drives a
     whole request through it: the request still answers 200. Telemetry that can
     break the thing it measures is a fault injector, not telemetry (§1 of the
     contract), and that rule does not stop at the header parser.
  2. THE REQUEST PATH DOES NO I/O. Ending a span appends a dict to a bounded
     list under one lock. Spans reach SQLite on a THROTTLED flush — at most one
     commit every FLUSH_SECS, taken by whichever request happens to be first
     past the deadline, exactly as `probes.py` folds its counters. A per-request
     `INSERT` + `commit` would have put fsync latency on `/signal/*`, which is
     the one route a visitor waits on.
  3. THE STORE IS THE EXISTING ONE. `traces.TraceStore` is already deployed,
     already pruned to 14 days, already admin-gated on read and already
     OTLP-exportable. A second store would need all four again, and would split
     one journey across two databases — which is precisely the failure the
     contract exists to prevent.
  4. SAMPLING IS THE BROWSER'S DECISION. An inbound `traceparent` with the
     sampled bit clear produces NO spans here (contract §4). A layer that
     sampled independently makes traces with holes in them, and a hole in a
     flame graph is indistinguishable from a gap in the work.

WHICH ROUTES ARE TRACED AT ALL is `tracing_http.py`'s allowlist, and static
asset serving is deliberately not among them — see the reasoning there.

NEVER A SECRET IN A SPAN. Attributes here are route templates, station ids,
outcome tokens and counts. Never a ticket (the ticket carries the trace id; the
trace never carries the ticket), never a session token, never a user id, never
subprocess output, never a stack. `traces.py` refuses several of these at intake
and the call sites below do not offer them.
"""

from __future__ import annotations

import os
import sys
import threading
import time

#: How long ended spans may sit in memory before a flush folds them in. Much
#: shorter than the counter plane's minute: a trace is looked at while somebody
#: is still standing in front of the exhibit, and two seconds of lag is the most
#: a live view tolerates. It is still ~1 commit/2 s under any load.
FLUSH_SECS = 2.0
#: Ended-but-unflushed spans. Bounded so an instrumentation bug costs memory
#: once and then stops; overflow is counted, never raised, never logged per
#: occurrence.
MAX_BUFFERED = 4096
#: Open spans per thread. A request that nests deeper than this has a bug.
MAX_DEPTH = 32
#: Mirrors the caps traces.py enforces at intake, so a value is truncated here
#: rather than silently dropped there.
ATTR_MAX = 24
ATTR_STR_MAX = 120
EVENT_MAX = 16

STATUSES = ("unset", "ok", "error")
KINDS = ("internal", "client", "server", "producer", "consumer")

_lock = threading.Lock()
_buffer: list = []
_store = None
_next_flush = 0.0
_dropped = 0
_local = threading.local()


# ---------------------------------------------------------------------------
# ids
# ---------------------------------------------------------------------------


def new_trace_id() -> str:
    """128-bit, lowercase hex, as `traceparent` carries it."""
    return os.urandom(16).hex()


def new_span_id() -> str:
    """64-bit, lowercase hex, as `traceparent` carries it."""
    return os.urandom(8).hex()


# ---------------------------------------------------------------------------
# spans
# ---------------------------------------------------------------------------


def _clean_attrs(raw) -> dict:
    """Narrow and cap exactly as traces.py will, so nothing is lost at intake."""
    out = {}
    if not isinstance(raw, dict):
        return out
    for k, v in raw.items():
        if len(out) >= ATTR_MAX or not isinstance(k, str) or len(k) > 64:
            continue
        if isinstance(v, (bool, int, float)):
            out[k] = v
        elif isinstance(v, str):
            out[k] = v[:ATTR_STR_MAX]
    return out


class Span:
    """One live span. End it exactly once; later calls are ignored.

    Usable as a context manager, which is how every call site outside the
    request wrapper should use it: an exception then closes the span as `error`
    and re-raises, so instrumentation cannot change control flow.
    """

    __slots__ = ("trace_id", "span_id", "_parent", "_name", "_kind", "_t0", "_wall0", "_a", "_e", "_ended")

    def __init__(self, trace_id: str, parent_id, name: str, attrs=None, kind: str = "internal"):
        self.trace_id = trace_id
        self.span_id = new_span_id()
        self._parent = parent_id
        self._name = name[:80]
        self._kind = kind
        self._t0 = time.monotonic()
        self._wall0 = int(time.time() * 1000)
        self._a = _clean_attrs(attrs)
        self._e: list = []
        self._ended = False

    # -- building ----------------------------------------------------------

    def child(self, name: str, attrs=None, kind: str = "internal") -> Span:
        try:
            return Span(self.trace_id, self.span_id, name, attrs, kind)
        except Exception:  # noqa: BLE001 - instrumentation never raises
            return NOOP

    def attr(self, key: str, value) -> None:
        try:
            if not self._ended:
                self._a.update(_clean_attrs({key: value}))
        except Exception:  # noqa: BLE001
            pass

    def event(self, name: str, attrs=None) -> None:
        try:
            if not self._ended and len(self._e) < EVENT_MAX:
                self._e.append({"n": name[:80], "t": int(time.time() * 1000), "a": _clean_attrs(attrs)})
        except Exception:  # noqa: BLE001
            pass

    def record_exception(self, err: BaseException) -> None:
        """An OTel `exception` event plus `error.type`.

        `exception.stacktrace` is part of the convention and is deliberately
        omitted — it is the one field that can carry arbitrary strings out of
        this process, `traces.py` refuses it at intake anyway, and stacks
        already live in clientlog.jsonl. The MESSAGE is omitted too, for the
        same reason one level down: a server-side exception message can quote a
        path, a header or a body fragment, none of which a span may carry.
        """
        try:
            kind = type(err).__name__[:80]
            self.event("exception", {"exception.type": kind})
            self._a.setdefault("error.type", kind)
        except Exception:  # noqa: BLE001
            pass

    def end(self, status: str = "unset", attrs=None, message=None) -> None:
        try:
            if self._ended:
                return
            self._ended = True
            if attrs:
                self._a.update(_clean_attrs(attrs))
            wire = {
                "t": self.trace_id,
                "s": self.span_id,
                "p": self._parent,
                "n": self._name,
                "kd": self._kind if self._kind in KINDS else "internal",
                "st": self._wall0,
                "d": max(0, int((time.monotonic() - self._t0) * 1000)),
                # `hidden_ms` is how much of a span's wall time the TAB spent
                # backgrounded (spa/src/analytics/trace.ts). A server has no
                # visibility state and no tab, so there is no honest value but
                # zero — inventing one would make the metric aggregates, which
                # subtract it, quietly wrong.
                "h": 0,
                "k": status if status in STATUSES else "unset",
            }
            if message:
                wire["m"] = str(message)[:200]
            if self._a:
                wire["a"] = self._a
            if self._e:
                wire["e"] = self._e
            _buffer_span(wire)
        except Exception:  # noqa: BLE001
            pass

    # -- context manager ---------------------------------------------------

    def __enter__(self) -> Span:
        # Entering makes this span the thread's ambient parent, so a `child()`
        # opened deeper in the call stack nests under it without anybody
        # threading a span through a signature. Leaving pops it — by identity,
        # not by position, so an early `return` inside the block cannot leave a
        # stale parent behind for the next request on this thread.
        push(self)
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        pop(self)
        if exc is not None and isinstance(exc, BaseException):
            self.record_exception(exc)
            self.end("error")
        else:
            self.end()
        return False


class _Noop(Span):
    """A span that does nothing, for every path that must not cost anything.

    Returned when tracing is off, when the inbound context says unsampled, or
    when a route is not in the allowlist. Every method is a no-op, so a call
    site needs no `if`.
    """

    __slots__ = ()

    def __init__(self):
        self.trace_id = ""
        self.span_id = ""
        self._ended = True

    def child(self, name, attrs=None, kind="internal"):
        return self

    def attr(self, key, value):
        pass

    def event(self, name, attrs=None):
        pass

    def record_exception(self, err):
        pass

    def end(self, status="unset", attrs=None, message=None):
        pass

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


NOOP = _Noop()


# ---------------------------------------------------------------------------
# the buffer and its throttled flush
# ---------------------------------------------------------------------------


def bind(store) -> None:
    """Attach the TraceStore. Until this is called spans are built and dropped,
    which is exactly what an import of these modules outside the server wants."""
    global _store, _next_flush
    with _lock:
        _store = store
        _next_flush = time.monotonic() + FLUSH_SECS


#: Which service produced a span, stamped on every one this module emits.
#: The store holds spans from the browser AND from here, and until this existed
#: the OTLP export labelled every one of them `kernel-hive-spa` with
#: `telemetry.sdk.language: webjs` — telling any consumer that a Python HTTP
#: handler was browser JavaScript. Wrong on its face, and it flattens two
#: services into one node on every service map that reads the export.
SERVICE_NAME = "kernel-hive-serve"


def _buffer_span(wire: dict) -> None:
    global _dropped, _buffer, _next_flush
    # Stamped here rather than at every call site: one place, no way to forget.
    wire.setdefault("a", {})["kh.service"] = SERVICE_NAME
    due = None
    with _lock:
        if len(_buffer) >= MAX_BUFFERED:
            _dropped += 1
            return
        _buffer.append(wire)
        now = time.monotonic()
        if _store is not None and now >= _next_flush:
            due, _buffer = _buffer, []
            # Re-armed BEFORE the write, so a slow or failing store cannot turn
            # every subsequent request into another attempt.
            _next_flush = now + FLUSH_SECS
    if due:
        _write(due)


def _write(spans: list) -> None:
    global _dropped
    store = _store
    if store is None or not spans:
        return
    try:
        # `session.id` is left unset on purpose: this plane never learns the
        # tab's session id (the header carries a trace, not an identity), and
        # traces.py labels it `unknown` rather than dropping the batch. When the
        # tab's own batch arrives it names the session, and the summary upgrades
        # — a batch that knows the session names it, one that does not never
        # erases one.
        store.record({"resource": {}, "spans": spans})
    except Exception:  # noqa: BLE001 - property 1
        with _lock:
            _dropped += len(spans)


def flush() -> int:
    """Fold whatever is buffered in now. Returns how many spans were folded.

    Nothing on the request path needs this — that is what the throttle is for.
    It exists for the tests and for a clean shutdown.
    """
    global _buffer, _next_flush
    try:
        with _lock:
            due, _buffer = _buffer, []
            _next_flush = time.monotonic() + FLUSH_SECS
        _write(due)
        return len(due)
    except Exception:  # noqa: BLE001
        return 0


def is_bound() -> bool:
    """Whether a store is attached. Off means every span is NOOP and free."""
    return _store is not None


def stats() -> dict:
    """What the buffer is holding right now. Tests, and a human at a REPL."""
    with _lock:
        return {"buffered": len(_buffer), "bound": _store is not None, "dropped": _dropped}


def reset_for_tests() -> None:
    global _store, _buffer, _next_flush, _dropped
    with _lock:
        _store = None
        _buffer = []
        _next_flush = 0.0
        _dropped = 0
    _local.stack = []


# ---------------------------------------------------------------------------
# the active span — one per request thread
# ---------------------------------------------------------------------------
#
# ThreadingHTTPServer gives every request its own thread, so a thread-local
# stack is a true ambient context here in a way it never is in the browser
# (see the note in spa/src/analytics/trace.ts). That is what lets gate.py,
# signal_route.py and the broker open a child without every caller in between
# having to thread a span object through its signature — which is the
# difference between instrumentation people add and instrumentation they don't.


def _stack() -> list:
    st = getattr(_local, "stack", None)
    if st is None:
        st = []
        _local.stack = st
    return st


def current() -> Span:
    """The innermost open span on this thread, or NOOP."""
    try:
        st = _stack()
        return st[-1] if st else NOOP
    except Exception:  # noqa: BLE001
        return NOOP


def push(span: Span) -> None:
    try:
        st = _stack()
        if len(st) < MAX_DEPTH:
            st.append(span)
    except Exception:  # noqa: BLE001
        pass


def pop(span: Span) -> None:
    try:
        st = _stack()
        for i in range(len(st) - 1, -1, -1):
            if st[i] is span:
                del st[i]
                return
    except Exception:  # noqa: BLE001
        pass


def child(name: str, attrs=None, kind: str = "internal") -> Span:
    """A child of this thread's innermost span, or NOOP when there is none.

    NOOP rather than a new trace, deliberately, and this is the opposite of what
    the browser does. A parentless span in the tab is still a journey worth
    following; a parentless span here is a fragment of a request whose root was
    not traced — an untraced route, or an unsampled visit — and emitting it
    would put an orphan in the trace list for every decision the allowlist
    already said it did not want to see.
    """
    return current().child(name, attrs, kind)


def start_trace(name: str, attrs=None, kind: str = "internal") -> Span:
    """A NEW root, for work with no request behind it — the walk-in watchdog.

    Only for a caller that runs on its own thread and genuinely starts a
    journey. Everything on a request path uses `child()`.
    """
    try:
        if not is_bound():
            return NOOP
        return Span(new_trace_id(), None, name, attrs, kind)
    except Exception:  # noqa: BLE001
        return NOOP


# The serving process puts `scripts/serve` on sys.path and imports this as
# `tracing`; the unit-test runner works from `scripts/` and reaches it as
# `serve.tracing`. Both names must be the SAME module object or two buffers
# accumulate and a flush drains half the spans — the identical trap probes.py
# documents. This module imports nothing but the standard library precisely so
# that both spellings can succeed.
sys.modules.setdefault("tracing", sys.modules[__name__])
sys.modules.setdefault("serve.tracing", sys.modules[__name__])

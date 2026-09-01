"""W3C Trace Context: parse and format `traceparent`.

The contract is docs/lab/TRACE-CONTEXT.md. This is the whole of it in code,
kept in one module because four layers implement the same rule and a second
parser is a second opinion about what a valid header is.

THE ONE BEHAVIOURAL RULE: a bad header starts a NEW trace, it never fails the
request. Telemetry that can break the thing it measures is a fault injector.
`parse()` therefore returns None rather than raising, for every malformed input
there is, and every caller treats None as "no parent".
"""

from __future__ import annotations

import re

# version-traceid-spanid-flags, all lowercase hex. Version 00 is the only one
# defined; the spec says a future version must still be parsed for the first
# two fields, which is why the version group is permissive and checked below.
_RE = re.compile(r"^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})$")
_ALL_ZERO_TRACE = "0" * 32
_ALL_ZERO_SPAN = "0" * 16

HEADER = "traceparent"


class TraceContext:
    """An inbound parent. Immutable; there is nothing to mutate."""

    __slots__ = ("trace_id", "span_id", "sampled")

    def __init__(self, trace_id: str, span_id: str, sampled: bool):
        self.trace_id = trace_id
        self.span_id = span_id
        self.sampled = sampled

    def __repr__(self) -> str:  # pragma: no cover - debugging only
        return f"TraceContext({self.trace_id[:8]}…/{self.span_id[:8]}…, sampled={self.sampled})"


def parse(header: str | None) -> TraceContext | None:
    """An inbound `traceparent`, or None for anything that is not one.

    None means START A NEW TRACE. It never means refuse the work, and no input
    to this function raises: it is fed a header from the open internet.
    """
    if not header or not isinstance(header, str):
        return None
    m = _RE.match(header.strip())
    if not m:
        return None
    version, trace_id, span_id, flags = m.groups()
    # `ff` is forbidden by the spec, and an all-zero id is the spec's own way of
    # saying "invalid" — both mean no usable parent rather than a parse error.
    if version == "ff" or trace_id == _ALL_ZERO_TRACE or span_id == _ALL_ZERO_SPAN:
        return None
    return TraceContext(trace_id, span_id, bool(int(flags, 16) & 0x01))


def format(trace_id: str, span_id: str, sampled: bool = True) -> str:
    """The header to send on an outbound hop."""
    return f"00-{trace_id}-{span_id}-{'01' if sampled else '00'}"


def header_of(handler) -> str | None:
    """The inbound header from a BaseHTTPRequestHandler, case-insensitively.

    `http.client.HTTPMessage` is already case-insensitive; this exists so a
    caller does not have to know that, and so there is one place to change if
    the serving plane ever stops being http.server.
    """
    try:
        return handler.headers.get(HEADER)
    except Exception:
        return None


#: W3C Trace Context Level 2's RESPONSE header. Same four fields as
#: `traceparent`, same spelling, opposite direction: it names the span the
#: server actually recorded for THIS response, so the caller can link its own
#: client span to the server trace instead of only hoping the id it sent was
#: honoured. This is OUR plane's mechanism and it is a real standard.
RESPONSE_HEADER = "traceresponse"

#: The vendor bridge, and nothing more. Instana's website-monitoring agent
#: parses `Server-Timing: intid;desc=<trace-id>` off a response and sets that
#: value as the beacon's `backendTraceId` — the one documented, non-invasive
#: way to make an EUM beacon point at a backend trace we minted ourselves. It
#: costs one header and buys vendor correlation for free; nothing in this repo
#: reads it (the browser prefers `traceresponse`, above), and removing it would
#: cost only the Instana join.
SERVER_TIMING_HEADER = "Server-Timing"

_TRACE_ID_RE = re.compile(r"^[0-9a-f]{32}$")
_SPAN_ID_RE = re.compile(r"^[0-9a-f]{16}$")


def response_headers(trace_id: str, span_id: str, sampled: bool = True) -> dict:
    """The two response headers that carry THIS response's trace back, or `{}`.

    `{}` for anything that is not a pair of well-formed ids — a NOOP span (id
    `""`, which is what every span is when tracing is unbound) most of all.
    Emitting `intid;desc=` with an empty or malformed value would not merely be
    useless: Instana silently drops a `backendTraceId` that is not 16 or 32
    lowercase hex, so a bad value is indistinguishable from no value on their
    side and pure noise on ours. Same rule as `parse()`: never raise, and never
    emit a shape a reader would have to guess about.
    """
    if not isinstance(trace_id, str) or not isinstance(span_id, str):
        return {}
    if not _TRACE_ID_RE.match(trace_id) or not _SPAN_ID_RE.match(span_id):
        return {}
    return {
        RESPONSE_HEADER: format(trace_id, span_id, sampled),
        SERVER_TIMING_HEADER: f"intid;desc={trace_id}",
    }

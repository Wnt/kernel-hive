"""POST /eum — first-party delivery of Instana EUM beacons.

WHY THIS EXISTS. The operator's phone runs a private-DNS ad/tracker blocker
(Blockada). A real visit from it produced a complete record in OUR OWN
telemetry plane — /clientlog, /analytics, /traces, all first-party — and ZERO
Instana beacons. Nothing was broken: the blocker simply refuses to resolve
Instana's reporting host, and a beacon that cannot resolve its destination is
not sent. Every such visitor is invisible in the Websites view while being
perfectly visible in ours, which is a bias, not a gap: the audience that
blocks trackers is exactly the audience that disappears.

The vendor SCRIPT was already self-hosted at /vendor/instana-eum.min.js
(scripts/serve-https-spa.sh's publish_instana_agent), so the beacon POST was
the one remaining third-party hop. This route removes it: the browser posts to
our own origin — same host as the page, same TLS, same cookie, no separate DNS
name to block — and this module forwards the body to Instana from the box.

THIS IS TEMPORARY AND DELETABLE. It exists only because the Instana
integration does. The long-term destination of this lab's telemetry is our own
plane, and when Instana goes, this file, its route, its config file and its
entry in the SPA's telemetry-path list go with it in one commit. Nothing else
depends on it. Note what the incident above already demonstrated: our own
plane never needed this, because it was first-party from the first line.

---------------------------------------------------------------------------
THE SECURITY POSTURE, in the order the request meets it
---------------------------------------------------------------------------

NOT AN OPEN PROXY, and that is a property of the code rather than of
validation. The destination is read from a file on the box
(config.INSTANA_EUM_UPSTREAM_FILE) and is the ONLY destination this module can
ever dial. There is no code path that reads a host, a URL, a path or a port
out of the request — not from the body, not from a query parameter, not from a
header. A request influences exactly two things: the bytes forwarded, and the
one client-IP header derived from the connection.

  * METHOD. POST only; anything else is 405. The vendor agent has a GET
    fallback (`Kb()` in the pinned v1.8.1 bundle: `(new Image).src = url + '?'
    + fields` for a sub-2000-byte beacon), but it is only reached when
    `navigator.sendBeacon` is absent, and this gallery is a WebGL/WebTransport
    app that no such browser can run. Read from the agent's own bytes, not
    assumed: the default `beaconBatchingTime` is 2000 ms (`M:2E3`), which
    selects the batched `Jb()` path — `sendBeacon(reportingUrl, body)`, with
    an XHR POST fallback. Both are POSTs.

  * ORIGIN, leniently. A PRESENT and mismatched Origin is refused; an ABSENT
    one is allowed. This is deliberately weaker than the strict equality
    `telemetry_routes._bad_origin` applies to /analytics and /traces, and the
    reason is the landmine this whole route is built around: those routes are
    reached by `khFetch`, where the Fetch spec guarantees an Origin on a POST.
    This one is reached by `navigator.sendBeacon` inside a VENDOR bundle we do
    not control, and engines have historically differed on whether a
    same-origin POST carries Origin at all. The threat the check exists for —
    another site spending a visitor's cookie to write into our tenant — always
    produces a mismatched Origin in a real browser, so "absent or equal"
    refuses it just as well while being unable to silently delete a whole
    engine's telemetry. `/vendor/` once 401'd for exactly that class of
    reason and took every visitor's beacons with it; a strict check here is
    the same mistake wearing a different hat.

  * AUTH. Exactly `/traces`: no wider. `/eum` is in gate.WALKIN_PATHS and in
    neither OPEN_PATHS nor OPEN_PREFIXES, so an invited session and a walk-in
    both reach it and a signed-out stranger does not. That is the same fence
    every other telemetry INGEST already stands behind, and matching it was a
    requirement, not a default.

    STATE THE COST: today a signed-out visitor at the /login or /walkin door
    DOES produce Instana beacons, because index.html's bootstrap runs
    unconditionally and the beacon went straight to the vendor with no fence
    of ours in the way. Through this route those beacons are 401'd and lost.
    The trade is deliberate — a route reachable by an anonymous stranger is a
    route that writes into our tenant for free — and it moves Instana's
    coverage to match our own plane's, which has always started at the door.

  * BODY SIZE. Capped at BODY_MAX below, framed by Content-Length only
    (chunked is refused, as everywhere else in this server).

  * HEADERS. Nothing the client sent is passed through. The upstream request
    is built from scratch with exactly three headers: Content-Type (chosen
    from an allowlist of the two the agent can produce), User-Agent and
    X-Forwarded-For (both derived, sanitised, and justified below).

  * REDIRECTS ARE NOT FOLLOWED. A 3xx from the upstream is a failure, logged
    as one. `_OPENER` is built without an HTTPRedirectHandler precisely so
    "follow the Location header" is not a behaviour this code has.

  * NOT TRACED, BY CONSTRUCTION. `tracing_http.route_of()` is an ALLOWLIST and
    `/eum` is not in it, so this route opens no span and emits no
    `Server-Timing`/`traceresponse`. That is load-bearing rather than tidy: a
    span here would be flushed to /traces, and every beacon would manufacture
    the next one. The client side of the same loop is closed by adding `/eum`
    to `KH_TELEMETRY_PATHS` (spa/src/analytics/instana.ts), which feeds both
    khFetch's ignore list and the agent's own `ignoreUrls`.

---------------------------------------------------------------------------
WHY THE FORWARD DOES NOT HAPPEN ON THE REQUEST THREAD
---------------------------------------------------------------------------

This is the part most likely to bite, so it is decided rather than defaulted.

The serving plane is a `ThreadingHTTPServer`, so a synchronous forward would
not block OTHER requests — it would block THIS one, and spawn a thread per
beacon that lives for as long as Instana takes to answer. The failure mode
that matters is not Instana being slow occasionally; it is Instana being
UNREACHABLE, which is precisely the scenario this route exists to survive. A
dead endpoint with a 5 s timeout, one batch every 2 s per tab and a handful of
tabs, is a steadily growing population of threads each sitting in a socket
timeout, and a visitor whose `sendBeacon` never completes. The gallery would
degrade because a vendor did — the one outcome that is not allowed.

So the request thread does the cheap, bounded work only: read the body,
enqueue, answer 200, done. One background worker drains the queue. The
consequences, stated:

  * A dead Instana costs ONE thread, forever, not one per beacon.
  * The queue is BOUNDED (QUEUE_MAX). When it is full the oldest batch is
    dropped, because a beacon's value decays and the newest one describes what
    the visitor is doing now. Drops are counted and logged, never silent.
  * DELIVERY IS NOT ACKNOWLEDGED. We answer 200 before knowing whether the
    upstream accepted, so our 200 means "queued", not "delivered". This costs
    nothing: `sendBeacon` discards the response entirely, and the agent's XHR
    fallback sets `responseType` and never inspects the status. Instana's own
    proxy guidance asks for a 2xx and no redirect, which is what we give.
  * ONE worker, not a pool. At the real rate (a batch every two seconds per
    open tab) a single thread with a sub-second upstream is idle almost all
    the time; a pool would only make a dead upstream burn more threads to
    reach the same drops. If this ever needs more, raise the worker count
    here — the queue is already the right shape for it.

FAILURE IS QUIET FOR THE VISITOR AND LOUD FOR US. The browser is told 200
whatever happens; every upstream failure goes to stderr (journald), rate
limited so a dead endpoint writes a line a minute instead of one per beacon.

---------------------------------------------------------------------------
THE GEOGRAPHY TRADE-OFF, AND WHY X-FORWARDED-FOR IS HERE
---------------------------------------------------------------------------

Instana's acceptor derives a visitor's Country/Subdivision facets and the
Geography map from the SOURCE IP of the beacon request — the beacon body
carries no IP at all ("The JavaScript agent does not have access to IP
addresses", 0250-monitoring-websites.md). Proxying therefore threatens to
collapse every visitor to the box's own egress IP, which would be a real loss
of a working capability.

The docs are NOT silent. 0250-monitoring-websites.md's proxy FAQ says, of
proxying the SaaS HTTP endpoints: "Make sure that Instana servers are aware of
the user IPs. Send an X-FORWARDED-FOR header to Instana servers with the
user's IP." 0025-installing-custom-edition.md is blunter: "The EUM acceptor in
the backend relies on the x-forwarded-for header in incoming requests to
determine the client's IP address." IBM states in the same breath that proxy
setups are unsupported, so this is a documented mechanism with no support
contract behind it — which is the right shape for something explicitly
temporary.

WHICH ENTRY OF X-FORWARDED-FOR, and why not the one `auth/routes._client_ip`
picks. That helper takes the LEFTMOST entry, which is correct for its job
(a rate-limit key and a log line, never authorization) and wrong for this one:
a client may send its own X-Forwarded-For, our edge APPENDS rather than
replaces, and the leftmost entry is therefore attacker-controlled. Asserting
an attacker-chosen IP to Instana would let any visitor place themselves
anywhere on the map. This module takes the RIGHTMOST entry instead — the one
our own edge appended, the only hop we trust — and refuses anything that does
not parse as an IP address. On the LAN listener there is no edge, so the
socket peer is the answer.

USER-AGENT IS FORWARDED TOO, and that is a second deliberate decision, not an
oversight. Instana derives the browser, OS and device facets from the request
User-Agent exactly as it derives geography from the source IP; forwarding only
the IP would trade one collapsed dimension for another, with every beacon
attributed to "Python-urllib". It is the visitor's own User-Agent, which
Instana received unchanged before this route existed, so nothing is disclosed
that was not already. It is length-capped and stripped of control characters
before it goes anywhere near a header.

Nothing else about the visitor is asserted upstream. No cookie, no Referer,
no Accept-Language, no session token — the beacon body already carries the
identity the operator chose to send (spa/src/analytics/instana.ts).
"""

from __future__ import annotations

import ipaddress
import json
import queue
import sys
import threading
import time
import urllib.request
from urllib.error import HTTPError, URLError

from config import INSTANA_EUM_UPSTREAM_FILE
from static_files import MIME

#: The first-party path the SPA's `ineum('reportingUrl', ...)` points at.
#: Short, sits beside the other telemetry ingests (/traces, /analytics,
#: /coverage), and names the vendor's own term for what travels over it — End
#: User Monitoring — rather than the vendor, so deleting the vendor does not
#: leave a route named after it behind.
PATH = "/eum"

#: One `sendBeacon` batch is at most 15 beacons (the agent's own `15<=O.length`
#: flush trigger), and a single beacon carrying a JS error's stack is the
#: largest thing in one. 128 KiB is roughly an order of magnitude over the
#: biggest batch measured on this gallery and an order under `traces.BODY_MAX`,
#: which accepts a very different shape of upload.
BODY_MAX = 128 * 1024

#: Content types the pinned agent can produce, and the only ones forwarded.
#: `sendBeacon` with a string body sends text/plain;charset=UTF-8; the
#: unbatched XHR path sends application/x-www-form-urlencoded;charset=UTF-8.
#: Matched on the media type alone so a charset parameter is not a refusal.
ALLOWED_CONTENT_TYPES = ("text/plain", "application/x-www-form-urlencoded")
DEFAULT_CONTENT_TYPE = "text/plain;charset=UTF-8"

#: Batches held in memory awaiting delivery. Sized against the failure it
#: bounds: an unreachable Instana for a few minutes of ordinary traffic,
#: rather than an unbounded buffer that turns a vendor outage into our OOM.
QUEUE_MAX = 512

#: Upstream socket timeout. Short enough that a black-holed endpoint does not
#: pin the worker for a minute, long enough for a real SaaS round trip from a
#: home line with a cold TLS session.
UPSTREAM_TIMEOUT = 5.0

#: At most one upstream-failure line per this many seconds. A dead endpoint
#: must be visible in journald without being the only thing in it.
LOG_EVERY_SECS = 60.0

#: User-Agent is forwarded (see the module docstring); cap it so a hostile or
#: broken client cannot make us send an unbounded header.
UA_MAX = 512

_lock = threading.Lock()
_queue: queue.Queue | None = None
_worker: threading.Thread | None = None
_upstream: str | None = None

#: Failure bookkeeping, read only through `_log_failure`.
_fail_count = 0
_drop_count = 0
_last_log = 0.0

#: An opener with NO redirect handler: `urlopen`'s default one would chase a
#: Location header, which is exactly the behaviour a fixed-destination
#: forwarder must not have. A 3xx therefore surfaces as an HTTPError.
_OPENER = urllib.request.OpenerDirector()
for _h in (
    urllib.request.HTTPHandler(),
    urllib.request.HTTPSHandler(),
    urllib.request.HTTPErrorProcessor(),
):
    _OPENER.add_handler(_h)


def upstream() -> str:
    """The one destination, read once from the box-side config file.

    The file holds a single line: the Instana EUM reporting URL from
    registry/local.env, published by scripts/serve-https-spa.sh at deploy time
    the same way the vendor agent itself is. It is a file rather than an
    environment variable because the systemd unit is committed to a PUBLIC
    repo with placeholder addresses in it, and the tenant's reporting URL is
    not publishable — the same reason `webrtc-ice-servers.json` is a file with
    a committed `.example` beside it.

    Absent or empty means NOT CONFIGURED, and the route 404s: a fresh clone, a
    contributor's box or a gallery with no Instana at all must behave exactly
    as it did before this file existed.
    """
    global _upstream
    if _upstream is None:
        try:
            _upstream = INSTANA_EUM_UPSTREAM_FILE.read_text().strip()
        except OSError:
            _upstream = ""
        if _upstream and not _upstream.startswith("https://"):
            # A plaintext or relative destination is a misconfiguration, not
            # something to half-honour: beacons carry a visitor's session id.
            sys.stderr.write("[serve] EUM proxy: upstream must be an https:// URL — disabled\n")
            _upstream = ""
    return _upstream


def _sanitise_header(value: str, cap: int) -> str:
    """One header value, with anything that could forge a header removed."""
    return "".join(c for c in value[:cap] if 32 <= ord(c) < 127).strip()


def _visitor_ip(handler) -> str:
    """The visitor's own IP, or "" when it cannot be established.

    RIGHTMOST X-Forwarded-For entry, not leftmost — see the module docstring.
    Anything that does not parse as an IP address is discarded rather than
    forwarded, so a header we cannot vouch for produces no assertion at all.
    """
    fwd = handler.headers.get("X-Forwarded-For") or ""
    candidates = [p.strip() for p in fwd.split(",") if p.strip()]
    if candidates:
        candidate = candidates[-1]
    elif handler.client_address:
        candidate = handler.client_address[0]
    else:
        return ""
    try:
        return str(ipaddress.ip_address(candidate))
    except ValueError:
        return ""


def _content_type(handler) -> str | None:
    """The forwarded Content-Type, or None when it is not one the agent sends."""
    raw = (handler.headers.get("Content-Type") or DEFAULT_CONTENT_TYPE).strip()
    media = raw.split(";")[0].strip().lower()
    if media not in ALLOWED_CONTENT_TYPES:
        return None
    return _sanitise_header(raw, 128) or DEFAULT_CONTENT_TYPE


def _read_body(handler) -> tuple[bytes | None, tuple[int, str] | None]:
    """Read the RAW beacon body. Mirrors `_read_json_body`'s framing rules —
    Content-Length only, no chunked — because the beacon is not JSON and must
    be forwarded byte for byte, escapes and all."""
    if "chunked" in (handler.headers.get("Transfer-Encoding") or "").lower():
        return None, (411, "chunked transfer coding not supported")
    try:
        n = int(handler.headers.get("Content-Length") or 0)
    except ValueError:
        return None, (411, "bad Content-Length")
    if n <= 0:
        return None, (411, "Content-Length required")
    if n > BODY_MAX:
        return None, (413, f"body exceeds {BODY_MAX} bytes")
    raw = b""
    while len(raw) < n:
        chunk = handler.rfile.read(n - len(raw))
        if not chunk:
            break
        raw += chunk
    return raw, None


def _log_failure(what: str) -> None:
    """Rate-limited upstream-failure line, with the totals since the last one."""
    global _last_log, _fail_count
    _fail_count += 1
    now = time.monotonic()
    if now - _last_log < LOG_EVERY_SECS:
        return
    _last_log = now
    sys.stderr.write(f"[serve] EUM proxy upstream failure ({what}); {_fail_count} failed, {_drop_count} dropped\n")


def _forward(body: bytes, content_type: str, ua: str, ip: str) -> None:
    """Deliver ONE batch. Never raises: this is the worker's whole body."""
    headers = {"Content-Type": content_type}
    if ua:
        headers["User-Agent"] = ua
    if ip:
        # Both spellings the docs name. X-REALER-IP is deliberately not
        # X-REAL-IP (0250-monitoring-websites.md is explicit about that), and
        # sending both costs nothing while covering whichever the acceptor
        # actually consults for this tenant.
        headers["X-Forwarded-For"] = ip
        headers["X-REALER-IP"] = ip
    req = urllib.request.Request(upstream(), data=body, headers=headers, method="POST")
    try:
        with _OPENER.open(req, timeout=UPSTREAM_TIMEOUT) as response:
            if response.status >= 300:
                _log_failure(f"status {response.status}")
    except HTTPError as e:
        _log_failure(f"status {e.code}")
    except (URLError, TimeoutError, OSError) as e:
        _log_failure(type(e).__name__)
    except Exception as e:  # noqa: BLE001 - the worker outlives every beacon
        _log_failure(type(e).__name__)


def _drain() -> None:
    """The single worker. Runs for the life of the process."""
    assert _queue is not None
    while True:
        item = _queue.get()
        try:
            _forward(*item)
        finally:
            _queue.task_done()


def _enqueue(item: tuple) -> None:
    """Hand one batch to the worker, starting it on first use.

    Full queue drops the OLDEST batch, not this one: the newest beacon
    describes what the visitor is doing now, and an upstream that has been
    unreachable long enough to fill the queue will not be helped by us holding
    a five-minute-old page load.
    """
    global _queue, _worker, _drop_count
    with _lock:
        if _queue is None:
            _queue = queue.Queue(maxsize=QUEUE_MAX)
        if _worker is None or not _worker.is_alive():
            _worker = threading.Thread(target=_drain, daemon=True, name="eum-proxy")
            _worker.start()
    while True:
        try:
            _queue.put_nowait(item)
            return
        except queue.Full:
            try:
                _queue.get_nowait()
                _queue.task_done()
                _drop_count += 1
            except queue.Empty:  # pragma: no cover - the worker just drained it
                pass


def _refuse(handler, code: int, message: str) -> None:
    handler._send(code, json.dumps({"error": message}), MIME[".json"], cache=False)


def dispatch(handler, method: str, public_origin: str) -> None:
    """Answer a request for PATH. The caller has already matched the path."""
    if not upstream():
        # Not configured: indistinguishable from a build that never had this
        # route, which is what an unconfigured checkout must look like.
        return _refuse(handler, 404, "not found")
    if method != "POST":
        return _refuse(handler, 405, "POST only")
    origin = handler.headers.get("Origin")
    if getattr(handler, "public", False) and origin and origin != public_origin:
        # PRESENT and wrong. Absent is allowed on purpose — module docstring.
        return _refuse(handler, 403, "bad origin")
    body, err = _read_body(handler)
    if err:
        return _refuse(handler, err[0], err[1])
    if not body:
        return _refuse(handler, 411, "empty body")
    content_type = _content_type(handler)
    if content_type is None:
        return _refuse(handler, 415, "unsupported content type")
    _enqueue(
        (
            body,
            content_type,
            _sanitise_header(handler.headers.get("User-Agent") or "", UA_MAX),
            _visitor_ip(handler),
        )
    )
    # 200 means QUEUED, not delivered — we answer before the upstream has been
    # dialled, which is the whole point of the queue. The agent discards the
    # response either way (`sendBeacon` cannot see it and the XHR fallback
    # never inspects it); Instana's own proxy guidance asks only for a 2xx and
    # no redirect, which is what this is. Shaped like /traces' reply so the
    # telemetry ingests answer alike.
    handler._send(200, json.dumps({"ok": True}), MIME[".json"], cache=False)
    return None

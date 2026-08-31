"""Static asset serving: MIME table, HTTP Range parsing, cache-policy/conditional-
GET (ETag/Last-Modified/If-None-Match/If-Modified-Since), the SPA/staging webroot
server, and the standalone auth UI pages (login/admin/account/link).

Route functions take the request `handler` (an osgallery_https_server.H
instance) as their first argument and call back into its `_send`/`_cors`
primitives — the handler class stays the single place that owns response
framing; this module owns picking which bytes and headers to send.

INDEX.HTML CARRIES ONE MORE THING: a `<meta name="traceparent">` tag, injected
into the SERVED BYTES only (see `_inject_traceparent` below) so a page load
joins the same trace as the request that served it — docs/lab/TRACE-CONTEXT.md
§8. This is a deliberate, narrow exception to "static asset serving is not
traced" (tracing_http.py's module docstring): every OTHER static file stays
untouched and unspanned; only the one response that IS the start of a visit
gets a span, and only index.html's bytes ever get rewritten.
"""

from __future__ import annotations

import email.utils
import re
from pathlib import Path

from config import AUTH_PAGES, AUTH_UI, WEBROOT

# Two module names for one module — see probes.py's note on why (deployed flat
# vs. imported as a package during tests). Unlike probes there is no third
# no-op fallback: tracing/tracecontext are in the same static box-sync name
# list as this file (scripts/lint/deploy-pair-imports.py), so "deployed
# without them" is not a state this plane can reach.
try:
    import tracecontext
    import tracing
except ImportError:  # pragma: no cover - import shape only
    from serve import tracecontext, tracing

MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".webmanifest": "application/manifest+json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".ttf": "font/ttf",
    ".map": "application/json",
    ".wasm": "application/wasm",
    ".txt": "text/plain",
    ".mp4": "video/mp4",
    ".m4v": "video/mp4",
    ".webm": "video/webm",
    ".vtt": "text/vtt; charset=utf-8",
    ".m4s": "video/iso.segment",
}

# Vite content-hashes its bundle output as <name>-<8+ chars>.<ext>; the
# generated icons under assets/generated/ are NOT hashed and must not be immutable.
_HASHED_ASSET = re.compile(r"^/(?:staging/[a-z0-9-]{1,24}/)?assets/[^/]+-[A-Za-z0-9_-]{8,}\.[a-z0-9]+$")


def _static_cache_policy(target: Path, path: str):
    """Cache-Control for a static file, or None for "no-store" (index.html:
    a redeploy must show on the next load, so it is never cached at all)."""
    if target.name == "index.html":
        return None
    if _HASHED_ASSET.match(path):
        return "public, max-age=31536000, immutable"
    if target.suffix.lower() == ".json":
        # Rendered runtime documents (gallery-manifest, poster-docs, boot/index):
        # reuse only after a revalidation, so a registry edit is live on the
        # next load — as a 304 when nothing changed.
        return "no-cache"
    # Poster thumbnails, boot-replay clips, generated icons: serve straight from
    # cache for a minute, then show the cached copy while revalidating in the
    # background — the grid <-> station round trip never waits on the network,
    # and a recaptured poster is on screen within a load or two.
    return "public, max-age=60, stale-while-revalidate=600"


#: Byte offset (right after the opening `<head ...>` tag) to inject the
#: traceparent meta into, cached per index.html path and keyed by the same
#: (mtime_ns, size) fingerprint the ETag already computes. The offset depends
#: only on the file's bytes, which change only on a redeploy — so a page load
#: costs one dict lookup, never a re-scan of the HTML, on every request after
#: the first. A redeploy changes the fingerprint and is picked up on its very
#: next request; nothing here ever serves a stale byte OFFSET (the bytes
#: themselves are re-read from disk every time regardless, same as any other
#: no-store file — this cache only remembers WHERE in them to cut).
_HEAD_SPLIT_CACHE: dict[str, tuple] = {}
_HEAD_RE = re.compile(rb"<head[^>]*>", re.IGNORECASE)


def _head_split_at(target: Path, data: bytes, fingerprint: tuple) -> int | None:
    """Offset right after `<head ...>` in `data`, or None if there is none
    (a foreign/corrupt index.html must still be served, just unmodified)."""
    key = str(target)
    cached = _HEAD_SPLIT_CACHE.get(key)
    if cached is not None and cached[0] == fingerprint:
        return cached[1]
    m = _HEAD_RE.search(data)
    idx = m.end() if m else None
    _HEAD_SPLIT_CACHE[key] = (fingerprint, idx)
    return idx


def _traceparent_meta(handler) -> bytes | None:
    """The `<meta name="traceparent" content="00-...-...-01">` tag for THIS
    request, or None.

    The exact tag name/attribute and the 4-part `00-<32hex>-<16hex>-<2hex>`
    shape are not documented by Instana anywhere — they come from reading the
    vendor's own minified website-monitoring agent, which looks for exactly
    `document.querySelector('meta[name="traceparent"]')` and silently ignores
    anything else. See docs/lab/TRACE-CONTEXT.md §8.

    The id is a REAL span, opened and ended right here and handed to
    `tracing.py` the same way every other request span is — recorded in our
    own store (traces.db), not merely stamped into a page and never seen
    again. That is what lets an operator find this page load in
    /admin/observability by the same id the tag advertises to Instana.

    FAIL SAFE, explicitly: any problem at all here — tracing not bound (a dev
    server with no store attached), a malformed inbound header, an exception
    from code this function does not control — returns None, and the caller
    serves the ORIGINAL bytes unchanged. A telemetry feature must never be
    able to break the gallery's front door (AGENTS.md rule 10 in spirit,
    TRACE-CONTEXT.md §7 in letter: "never fail a request because of a
    header").
    """
    try:
        if not tracing.is_bound():
            return None
        # An inbound traceparent on the DOCUMENT request itself is not a shape
        # a plain browser navigation ever produces today, but honouring it
        # anyway costs nothing and keeps this consistent with every other hop
        # in the contract: a sampled parent is joined, not overridden.
        parent = tracecontext.parse(tracecontext.header_of(handler))
        if parent is not None and not parent.sampled:
            return None
        trace_id = parent.trace_id if parent is not None else tracing.new_trace_id()
        span = tracing.Span(trace_id, parent.span_id if parent else None, "serve.page", None, "server")
        span.end("ok", {"http.response.status_code": 200})
        header = tracecontext.format(span.trace_id, span.span_id)
        return f'<meta name="traceparent" content="{header}">'.encode("ascii")
    except Exception:  # noqa: BLE001 - telemetry must never break the page
        return None


def _inject_traceparent(handler, target: Path, data: bytes, fingerprint: tuple) -> bytes:
    """`data` (index.html's bytes) with the traceparent meta spliced into
    `<head>`, or `data` UNCHANGED when tracing is unavailable or there is no
    `<head>` to inject after — never anything else, never a raise."""
    try:
        idx = _head_split_at(target, data, fingerprint)
        if idx is None:
            return data
        tag = _traceparent_meta(handler)
        if tag is None:
            return data
        return data[:idx] + tag + data[idx:]
    except Exception:  # noqa: BLE001 - telemetry must never break the page
        return data


def parse_range(header, size):
    """Parse a single 'bytes=start-end' Range header into inclusive
    (start, end) byte offsets, or None when the header is absent, malformed,
    multi-range, or not a bytes range (caller then serves a 200 full body).
    A satisfiable range is clamped to the file; an out-of-window range still
    returns offsets and the caller emits 416 for the unsatisfiable case
    (start > end or start >= size)."""
    if not header:
        return None
    header = header.strip()
    if not header.lower().startswith("bytes="):
        return None
    spec = header[len("bytes=") :].strip()
    if "," in spec or "-" not in spec:
        return None  # multi-range / malformed -> fall back to full body
    first, _, last = spec.partition("-")
    first, last = first.strip(), last.strip()
    try:
        if first == "":
            # suffix range: bytes=-N -> final N bytes
            if last == "":
                return None
            n = int(last)
            if n <= 0:
                return None
            start = max(0, size - n)
            end = size - 1
        else:
            start = int(first)
            end = int(last) if last != "" else size - 1
            if end >= size:
                end = size - 1
    except ValueError:
        return None
    if start < 0:
        return None
    return (start, end)


def not_modified(handler, etag, mtime):
    """Conditional GET: True when the client's cached copy is still current."""
    inm = handler.headers.get("If-None-Match")
    if inm:
        return etag in [t.strip() for t in inm.split(",")] or inm.strip() == "*"
    ims = handler.headers.get("If-Modified-Since")
    if ims:
        try:
            since = email.utils.parsedate_to_datetime(ims).timestamp()
        except (TypeError, ValueError, OverflowError):
            return False
        return int(mtime) <= int(since)
    return False


def serve_auth_ui(handler, path):
    """The sign-in and people-management pages.

    Deliberately NOT part of the SPA bundle: a signed-out visitor should not
    have to download a WebGL museum (or learn every asset name in it) to be
    shown a login button.
    """
    name = AUTH_PAGES.get(path) or path[len("/ui/") :]
    target = (AUTH_UI / name).resolve()
    if target != AUTH_UI and AUTH_UI not in target.parents:
        return handler._send(403, "forbidden\n", "text/plain")
    if not target.is_file():
        return handler._send(404, "not found\n", "text/plain")
    ctype = MIME.get(target.suffix, "application/octet-stream")
    return handler._send(200, target.read_bytes(), ctype, cache=False)


def serve_static(handler, path):
    # The auth pages carry no <link rel=icon>, so browsers ask for the
    # conventional /favicon.ico (already OPEN on the public gate); answer it
    # with the SPA's generated icon instead of a 404 on every sign-in.
    if path == "/favicon.ico":
        path = "/assets/generated/favicon.ico"
    rel = path.lstrip("/")
    target = (WEBROOT / rel).resolve()
    # containment guard — a true ancestor check (NOT a string prefix, which
    # would wrongly admit a sibling like `<webroot>-secrets/…`). WEBROOT is
    # already .resolve()'d at startup, so symlink/`..` escapes fail this too.
    if target != WEBROOT and WEBROOT not in target.parents:
        return handler._send(403, "forbidden\n", "text/plain")

    # A staged UI (scripts/dev/stage.sh) lives at webroot/staging/<session>/
    # — a complete vite build with base=/staging/<session>/ plus its own
    # rendered gallery-manifest.json + poster-docs.json. Its client routes
    # fall back to ITS index.html, never the live one.
    staged = re.match(r"^/staging/([a-z0-9-]{1,24})(?:/|$)", path)
    staged_index = (WEBROOT / "staging" / staged.group(1) / "index.html") if staged else None

    if path == "/" or target.is_dir():
        target = staged_index if staged_index and staged_index.is_file() else WEBROOT / "index.html"

    if not target.is_file():
        # UI client-side route -> index.html, but NEVER for reserved API
        # prefixes or anything carrying a file extension (missing hashed
        # assets must 404 to expose deploy skew; a stray GET /restore/* or
        # /signal/* must 404, not silently render the app).
        reserved = (
            "/signal/",
            "/webrtc/",
            "/restore/",
            "/assets/",
            "/boot/",
            "/healthz",
            "/clientlog",
            "/clientcmd",
        )
        if staged_index and staged_index.is_file() and not Path(path).suffix:
            target = staged_index
        elif not path.startswith(reserved) and not Path(path).suffix:
            target = WEBROOT / "index.html"
        else:
            return handler._send(404, "not found\n", "text/plain")

    ctype = MIME.get(target.suffix.lower(), "application/octet-stream")

    try:
        st = target.stat()
    except Exception:
        return handler._send(404, "not found\n", "text/plain")
    size = st.st_size
    # Validators + an EXPLICIT policy for every static file. Before this,
    # static responses carried no Cache-Control / Last-Modified / ETag at
    # all, so browsers could neither reuse nor revalidate them — every
    # poster thumbnail was a full 200 on every grid visit. (Adding a
    # Last-Modified without a Cache-Control would be worse: heuristic
    # freshness would let a re-rendered manifest or recaptured poster go
    # stale for hours.)
    etag = f'"{st.st_mtime_ns:x}-{size:x}"'
    last_mod = email.utils.formatdate(st.st_mtime, usegmt=True)
    cache_ctl = _static_cache_policy(target, path)
    if cache_ctl is not None and not_modified(handler, etag, st.st_mtime):
        handler.send_response(304)
        handler.send_header("ETag", etag)
        handler.send_header("Cache-Control", cache_ctl)
        handler._cors()
        handler.end_headers()
        return
    extra = {"ETag": etag, "Last-Modified": last_mod, "Cache-Control": cache_ctl} if cache_ctl is not None else {}

    # HTTP Range (single "bytes=start-end") — lets <video> scrub/seek without
    # pulling the whole clip. Absent/malformed/multi-range headers fall
    # through to the plain 200 full-body path.
    rng = parse_range(handler.headers.get("Range"), size)
    if rng is None:
        try:
            data = target.read_bytes()
        except Exception:
            return handler._send(404, "not found\n", "text/plain")
        if target.name == "index.html":
            # Only index.html, and only the bytes on the wire — never
            # spa/index.html on disk (untouched; a build/deploy never bakes a
            # stale id into the artifact, because there is nothing to bake:
            # the id is minted fresh per request, right here).
            data = _inject_traceparent(handler, target, data, (st.st_mtime_ns, size))
        return handler._send(200, data, ctype, cache=cache_ctl is not None, extra=extra)

    start, end = rng  # inclusive offsets
    if start > end or start >= size:
        # Unsatisfiable (RFC 7233 §4.4): 416 + Content-Range: bytes */size.
        handler.send_response(416)
        handler.send_header("Content-Range", f"bytes */{size}")
        handler.send_header("Content-Length", "0")
        handler.send_header("Accept-Ranges", "bytes")
        handler._cors()
        handler.end_headers()
        return

    try:
        with target.open("rb") as f:
            f.seek(start)
            data = f.read(end - start + 1)
    except Exception:
        return handler._send(404, "not found\n", "text/plain")

    # 206 partial — mirror _send's header/HEAD-guard idiom, plus range headers.
    handler.send_response(206)
    handler.send_header("Content-Type", ctype)
    handler.send_header("Content-Length", str(len(data)))
    handler.send_header("Content-Range", f"bytes {start}-{end}/{size}")
    handler.send_header("Accept-Ranges", "bytes")
    handler._cors()
    if cache_ctl is None:
        handler.send_header("Cache-Control", "no-store")
    for k, v in extra.items():
        handler.send_header(k, v)
    handler.end_headers()
    if handler.command != "HEAD":
        handler.wfile.write(data)

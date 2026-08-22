#!/usr/bin/env python3
"""retronet-proxy — the corpus HTTP/1.0 server of the web plane, two doors.

Runs INSIDE the gateway CT (951, 10.99.0.2). It serves the SAME corpus two ways:

  * FORWARD PROXY on :3128 — an era browser sets its HTTP proxy to 10.99.0.2:3128
    and sends absolute-form requests (`GET http://host/path HTTP/1.0`).
  * :80 ORIGIN (vhost) — a browser with NO proxy and DNS=10.99.0.2 (handed out by
    retronet-dhcp; every name resolves to the gateway via retronet-dns) sends an
    ordinary origin-form request (`GET /path HTTP/1.0` + `Host: host`), which
    lands here on :80 and is served by Host. This is the "seamless, no-proxy" web:
    type a URL, it resolves to the gateway, and :80 serves the corpus.

Both doors run the SAME handler over the SAME corpus, search routing, content
types and miss page — only the request-line form differs (absolute vs origin),
and resolve_target() already accepts both. An un-mirrored site still resolves to
the gateway and gets the period miss page on either door — authentic.

THE SECURITY PROPERTY, in one sentence: this program NEVER opens a connection to
the real internet. There is no upstream fetch, no DNS lookup, no fallback. A
request for a host that is not in the corpus returns a period "not in the
museum's internet" 404 page — it does not touch the network. The ONLY outbound
connection this program can make is to the CT-local search backend
(default 127.0.0.1:8090), made in exactly one function (`forward_to_search`);
everything else is local file I/O. The CT also has no default route (see
docs/lab/retronet/GATEWAY.md), so even a bug here has nowhere to send a packet.

A browser toolbar search (its built-in search box, e.g. a Google query) is
302-redirected to the reserved search host with the terms kept — still local:
that host resolves back here and is routed to the search backend, never the
internet.

HTTP/1.0 by construction: every response is HTTP/1.0 with an explicit
Content-Length and Connection: close — no chunked transfer, no gzip — which is
what era browsers (Netscape 4, IE5) expect from a proxy.

Config (systemd EnvironmentFile /etc/retronet/proxy.env, or the environment):
  RN_PROXY_LISTEN          forward-proxy bind host:port (default 10.99.0.2:3128)
  RN_PROXY_ORIGIN_LISTEN   :80 origin bind host:port    (default 10.99.0.2:80; blank disables)
  RN_PROXY_CORPUS          corpus root                  (default /data/retronet/corpus)
  RN_PROXY_SEARCH_HOSTS    reserved hostnames -> search (default search.retronet)
  RN_PROXY_SEARCH_BACKEND  the search service host:port (default 127.0.0.1:8090)

As-built: docs/lab/retronet/WEB-PROXY.md. Stream W1 of the web plane
(docs/lab/retronet/WEB-PLANE-PLAN.md).
"""

from __future__ import annotations

import http.client
import json
import mimetypes
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlsplit

from rn_proxy_pages import era_page, is_search_engine, search_nav, search_query_of

# --- defaults (every one overridable from /etc/retronet/proxy.env) -----------
DEF_LISTEN = "10.99.0.2:3128"
DEF_ORIGIN_LISTEN = "10.99.0.2:80"
DEF_CORPUS = "/data/retronet/corpus"
DEF_SEARCH_HOSTS = "search.retronet"
DEF_SEARCH_BACKEND = "127.0.0.1:8090"
# Misses are journalled here, at the corpus root beside sites.json — the one path both containers
# share. era-press rotates and reads it; see era_requests.py.
MISS_JOURNAL = "_requests.jsonl"


def record_miss(corpus_root: str, host: str, path: str) -> None:
    """Append one miss to the journal. One open/write/close so the crawler can rotate the file out from
    under us safely (a short O_APPEND write is atomic); errors are swallowed — a hint channel must
    never break serving."""
    try:
        rec = json.dumps({"url": f"http://{host}{path}", "t": int(time.time())}, ensure_ascii=True)
        with open(os.path.join(corpus_root, MISS_JOURNAL), "a", encoding="ascii") as fh:
            fh.write(rec + "\n")
    except OSError:
        pass


# The proxy's OWN notices (the miss/error pages below) are authored in Latin-1
# with numeric entities. Corpus content is served untouched — see content_type.
TEXT_CHARSET = "iso-8859-1"

# Content type by extension. mimetypes fills any gap; the final fallback is
# application/octet-stream. The corpus is a raw archival mirror (WEB-PLANE-PLAN
# "fidelity, not downgrade"), so this spans original period types — HTML, GIF,
# JPEG, PNG, JS, CSS — served exactly as stored, never re-encoded.
CONTENT_TYPES = {
    ".html": "text/html",
    ".htm": "text/html",
    ".txt": "text/plain",
    ".css": "text/css",
    ".js": "application/x-javascript",
    ".gif": "image/gif",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".png": "image/png",
    ".ico": "image/x-icon",
    ".xbm": "image/x-xbitmap",
    ".au": "audio/basic",
    ".mid": "audio/midi",
    ".midi": "audio/midi",
    ".wav": "audio/x-wav",
    ".zip": "application/zip",
    ".pdf": "application/pdf",
    # Era server-script extensions. In the corpus these are archived RESPONSES —
    # the HTML the server emitted, not the script — so they render as HTML, not
    # download. Without this, Space Jam's frame home (/ meta-refreshes to
    # index.cgi) is served application/octet-stream and downloads. (ERA-PRESS.md;
    # a bytes-level sniff below catches the ones no extension names.)
    ".cgi": "text/html",
    ".shtml": "text/html",
    ".asp": "text/html",
    ".phtml": "text/html",
    ".pl": "text/html",
    ".cfm": "text/html",
}

# Markers an archived HTML response opens with, for the octet-stream sniff below.
HTML_SNIFF_MARKERS = (b"<!doctype html", b"<html", b"<head", b"<title", b"<body", b"<frameset")

# A hostname we are willing to serve as a corpus directory. Anything else is a
# malformed request, never a filesystem path.
HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")


def content_type(path: str) -> str:
    # Fidelity, not downgrade (WEB-PLANE-PLAN.md): the corpus is the raw archived
    # bytes, so serve the type by extension and impose NO charset — an era page's
    # own <meta> (or the browser's default) decides, exactly as it did in period.
    ext = os.path.splitext(path)[1].lower()
    return CONTENT_TYPES.get(ext) or mimetypes.guess_type(path)[0] or "application/octet-stream"


def looks_like_html(data: bytes) -> bool:
    # A last-resort sniff for the octet-stream fallback ONLY: an archived RESPONSE
    # whose extension names nothing (a bare /cmp/pressbox, a .php/.jsp/.dll home)
    # but whose bytes are plainly HTML should render, not download. It must start
    # with markup and carry an HTML marker in its first 1 KB — so real binaries,
    # which almost never begin with '<', are untouched. No bytes are rewritten;
    # only the header label is corrected.
    head = data[:1024].lstrip(b"\xef\xbb\xbf \t\r\n").lower()
    return head.startswith(b"<") and any(m in head for m in HTML_SNIFF_MARKERS)


class ProxyServer(ThreadingHTTPServer):
    """One instance, shared across handler threads. Holds the immutable config
    and a cheap mtime-checked cache of the corpus manifest (sites.json)."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, corpus_root, search_hosts, search_backend):
        super().__init__(addr, ProxyHandler)
        self.corpus_root = os.path.realpath(corpus_root)
        self.search_hosts = frozenset(h.lower() for h in search_hosts)
        # The canonical search host (first configured): where the miss-page search
        # box and redirected toolbar searches point. It resolves back here.
        self.search_host = next((h.lower() for h in search_hosts), DEF_SEARCH_HOSTS)
        self.search_backend = search_backend  # (host, port)
        self._sites_lock = threading.Lock()
        self._sites_mtime: float | None = None
        self._sites_hosts: frozenset[str] = frozenset()

    def known_hosts(self) -> frozenset[str]:
        """Hosts named in the corpus manifest. Absent/broken manifest -> empty;
        an empty corpus is a valid corpus."""
        path = os.path.join(self.corpus_root, "sites.json")
        with self._sites_lock:
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                self._sites_mtime, self._sites_hosts = None, frozenset()
                return self._sites_hosts
            if mtime != self._sites_mtime:
                self._sites_mtime = mtime
                self._sites_hosts = _load_sites(path)
            return self._sites_hosts


def _load_sites(path: str) -> frozenset[str]:
    try:
        with open(path, "rb") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return frozenset()
    hosts = set()
    if isinstance(data, list):
        for entry in data:
            if isinstance(entry, dict) and isinstance(entry.get("host"), str):
                hosts.add(entry["host"].lower())
    return frozenset(hosts)


class ProxyHandler(BaseHTTPRequestHandler):
    # HTTP/1.0: no keep-alive, no chunked. Every reply carries Content-Length and
    # closes the connection, which is exactly what an era browser proxy wants.
    protocol_version = "HTTP/1.0"
    server_version = "RetroNetProxy/1.0"
    sys_version = ""

    def handle_one_request(self):
        # An era browser aborts connections constantly — hitting Stop, or closing
        # a slow inline image. That surfaces here as a reset while we are still
        # writing the response; it is normal on the retronet, not a server fault,
        # so we close quietly instead of dumping a traceback to journald.
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True

    # -- request entry points -------------------------------------------------
    def do_GET(self):
        self.handle_request(body=True)

    def do_HEAD(self):
        self.handle_request(body=False)

    def do_POST(self):
        # A POST only makes sense for the search service (a form submit). The
        # corpus is read-only, so a POST to it is a period 405.
        target = self.resolve_target()
        if target is None:
            return
        host, path, query = target
        if host in self.server.search_hosts:
            return self.forward_to_search(host, path, query)
        self.send_era(
            405,
            "405 Method Not Allowed",
            "Method Not Allowed",
            ["The museum's pages are read-only. Only the search service takes a POST."],
        )

    def do_CONNECT(self):
        # CONNECT is how a browser asks a proxy to tunnel TLS to the real
        # internet. We have no upstream and no TLS; refuse, do not tunnel.
        self.send_era(
            501,
            "501 Not Implemented",
            "No Tunnels Here",
            [
                "This proxy does not open tunnels to the live internet &#151; there "
                "is no live internet behind it. Browse http:// pages from the museum "
                "corpus instead."
            ],
        )

    # -- the corpus/search split ---------------------------------------------
    def handle_request(self, *, body: bool):
        target = self.resolve_target()
        if target is None:
            return
        host, path, query = target
        if host in self.server.search_hosts:
            return self.forward_to_search(host, path, query, body=body)
        # A browser toolbar search (e.g. Google) -> hand it to the museum's own
        # search with the terms kept, rather than a dead miss. Still local: the
        # redirect points at the reserved search host, served by this gateway.
        if is_search_engine(host):
            terms = search_query_of(query)
            if terms is not None:
                return self.send_redirect(f"http://{self.server.search_host}/search?q={quote(terms)}")
        self.serve_corpus(host, path, body=body)

    def resolve_target(self):
        """Return (host, path, query) or emit an error page and return None.

        A proxy request is absolute-form: `GET http://host/path HTTP/1.0`. We
        also accept origin-form with a Host header so plain `curl` (no -x) works
        for testing. We speak only http — never https/ftp/tunnels."""
        split = urlsplit(self.path)
        if split.scheme or split.netloc:
            if split.scheme and split.scheme != "http":
                self.send_era(
                    400,
                    "400 Bad Request",
                    "Only http Here",
                    [
                        f"The museum serves <B>http://</B> pages only; it cannot fetch "
                        f"<B>{split.scheme}://</B> from anywhere.",
                    ],
                )
                return None
            host = split.hostname
        else:
            host = (self.headers.get("Host") or "").split(":")[0].strip().lower() or None
        if not host or not HOST_RE.match(host):
            self.send_era(
                400,
                "400 Bad Request",
                "Set Your Proxy",
                [
                    "This is the retronet HTTP proxy. Point your browser's HTTP proxy "
                    "at this address and request an <B>http://</B> page.",
                ],
            )
            return None
        return host, split.path, split.query

    # -- corpus serving -------------------------------------------------------
    def serve_corpus(self, host: str, path: str, *, body: bool):
        target = self.corpus_path(host, path)
        if target and os.path.isdir(target):
            idx = os.path.join(target, "index.html")
            target = idx if os.path.isfile(idx) else None
        if not target or not os.path.isfile(target):
            return self.send_miss(host, path)
        try:
            with open(target, "rb") as fh:
                data = fh.read()
        except OSError:
            return self.send_era(
                403,
                "403 Forbidden",
                "Cannot Read That",
                ["The museum has this page on file but could not open it."],
            )
        ctype = content_type(target)
        if ctype == "application/octet-stream" and looks_like_html(data):
            ctype = "text/html"
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(data)

    def corpus_path(self, host: str, path: str):
        """Map (host, url-path) to a file under corpus/<host>, or None if the
        request escapes the jail. HOST_RE already forbids '/' and '..' in host."""
        root = self.server.corpus_root
        site_root = os.path.join(root, host)
        rel = unquote(path).lstrip("/")
        if rel == "" or rel.endswith("/"):
            rel += "index.html"
        target = os.path.normpath(os.path.join(site_root, rel))
        # Lexical jail: normpath collapsed any '..'; the result must stay under
        # the site root. Then a realpath jail defends against a symlink escape.
        if target != site_root and not target.startswith(site_root + os.sep):
            return None
        real = os.path.realpath(target)
        real_site = os.path.realpath(site_root)
        if real != real_site and not real.startswith(real_site + os.sep):
            return None
        return target

    def send_miss(self, host: str, path: str):
        """A cache miss is a museum notice, never a fetch. If we know the host
        (it has a corpus dir or a manifest entry) the copy says 'this page';
        otherwise it says 'this host is not on the retronet at all'. The miss is
        also RECORDED: it is the most honest signal this system produces about
        what it lacks — a station asked, and we had nothing. See `record_miss`."""
        record_miss(self.server.corpus_root, host, path)
        known = os.path.isdir(os.path.join(self.server.corpus_root, host)) or (host in self.server.known_hosts())
        where = f"http://{host}{path}"
        if known:
            paras = [
                f"The page <B>{where}</B> is not in the museum's copy of <B>{host}</B>.",
                "Only pages that were archived into the corpus can be shown. There is "
                "no live internet to fall through to.",
            ]
        else:
            paras = [
                f"<B>{host}</B> is not part of the museum's internet.",
                "This is an offline gallery of the 1990s web. Only the sites that have "
                "been archived into the corpus exist here &#151; nothing is fetched "
                "from the live internet, because there is none.",
            ]
        self.send_era(
            404,
            "404 Not Found",
            "Not in the Museum's Internet",
            paras,
            extra=search_nav(self.server.search_host),
        )

    # -- the ONE outbound path: the CT-local search backend -------------------
    def forward_to_search(self, host, path, query, *, body: bool = True):
        """Proxy to the search service. This is the only place in the whole
        program that opens a socket to anywhere, and it can only reach the fixed,
        CT-local backend from config (default 127.0.0.1:8090) — never a name
        from the request, never the internet."""
        backend_host, backend_port = self.server.search_backend
        selector = path + ("?" + query if query else "")
        length = self.headers.get("Content-Length")
        payload = self.rfile.read(int(length)) if length and self.command == "POST" else None
        try:
            conn = http.client.HTTPConnection(backend_host, backend_port, timeout=15)
            headers = {"Host": host, "Accept": self.headers.get("Accept", "*/*")}
            if payload is not None:
                headers["Content-Type"] = self.headers.get("Content-Type", "application/x-www-form-urlencoded")
            conn.request(self.command, selector or "/", body=payload, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            ctype = resp.getheader("Content-Type", "text/html; charset=" + TEXT_CHARSET)
            status = resp.status
            conn.close()
        except OSError:
            # W3 not up yet, or crashed. Clean period 502 — still no internet.
            return self.send_era(
                502,
                "502 Bad Gateway",
                "Search Is Offline",
                [
                    "The museum's search desk is not answering right now. The pages in "
                    "the corpus are still reachable directly by address."
                ],
            )
        # Re-emit as clean HTTP/1.0 no matter what the backend framed.
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(data)

    # -- helpers --------------------------------------------------------------
    def send_era(self, code, title, heading, paras, extra=""):
        data = era_page(title, heading, paras, extra)
        self.send_response(code)
        self.send_header("Content-Type", f"text/html; charset={TEXT_CHARSET}")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def send_redirect(self, url):
        """A period 302 to a LOCAL address (the museum search). Carries a small
        body with a link, for the rare browser that will not auto-follow."""
        data = era_page(
            "302 Found",
            "To the Museum's Search",
            [f'Handing your search to <A HREF="{url}">the museum&#146;s search desk</A>&#133;'],
        )
        self.send_response(302)
        self.send_header("Location", url)
        self.send_header("Content-Type", f"text/html; charset={TEXT_CHARSET}")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def log_message(self, fmt, *args):
        # One tidy line to journald (systemd captures stdout/stderr). No IPs of
        # any upstream because there is no upstream.
        sys.stderr.write(f"retronet-proxy {self.address_string()} - {fmt % args}\n")


# --- config + main -----------------------------------------------------------
def split_hostport(value: str, default_port: int):
    value = value.strip()
    if ":" in value:
        host, _, port = value.rpartition(":")
        return host, int(port)
    return value, default_port


def load_config():
    listen = os.environ.get("RN_PROXY_LISTEN", DEF_LISTEN)
    origin = os.environ.get("RN_PROXY_ORIGIN_LISTEN", DEF_ORIGIN_LISTEN).strip()
    corpus = os.environ.get("RN_PROXY_CORPUS", DEF_CORPUS)
    hosts = os.environ.get("RN_PROXY_SEARCH_HOSTS", DEF_SEARCH_HOSTS)
    backend = os.environ.get("RN_PROXY_SEARCH_BACKEND", DEF_SEARCH_BACKEND)
    bind_host, bind_port = split_hostport(listen, 3128)
    # The :80 origin door is optional — a blank RN_PROXY_ORIGIN_LISTEN disables it
    # (e.g. a run where nothing may bind a privileged port).
    origin_addr = None
    if origin:
        origin_host, origin_port = split_hostport(origin, 80)
        origin_addr = (origin_host, origin_port)
    search_hosts = [h for h in re.split(r"[,\s]+", hosts) if h]
    backend_host, backend_port = split_hostport(backend, 8090)
    return {
        "addr": (bind_host, bind_port),
        "origin_addr": origin_addr,
        "corpus": corpus,
        "search_hosts": search_hosts,
        "search_backend": (backend_host, backend_port),
    }


def make_server(addr, cfg):
    return ProxyServer(addr, cfg["corpus"], cfg["search_hosts"], cfg["search_backend"])


def main():
    cfg = load_config()
    os.makedirs(cfg["corpus"], exist_ok=True)
    # Same handler, same corpus, on both doors: the forward proxy (:3128) and,
    # when configured, the :80 origin (vhost) that the no-proxy web rides on.
    servers = [make_server(cfg["addr"], cfg)]
    if cfg["origin_addr"]:
        servers.append(make_server(cfg["origin_addr"], cfg))
    primary = servers[0]
    hosts = ",".join(sorted(primary.search_hosts)) or "(none)"
    backend = f"{primary.search_backend[0]}:{primary.search_backend[1]}"
    doors = "  ".join(f"{s.server_address[0]}:{s.server_address[1]}" for s in servers)
    sys.stderr.write(
        f"retronet-proxy: listening on {doors}  corpus={primary.corpus_root}  search={hosts} -> {backend}\n"
    )
    # Extra door(s) in daemon threads; the primary in the main thread. Each
    # ProxyServer already threads per-connection, so this just runs two accept
    # loops over the one shared, immutable config.
    for srv in servers[1:]:
        threading.Thread(target=srv.serve_forever, name="origin", daemon=True).start()
    try:
        primary.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        for srv in servers[1:]:
            srv.shutdown()
        for srv in servers:
            srv.server_close()


if __name__ == "__main__":
    main()

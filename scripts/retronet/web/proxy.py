#!/usr/bin/env python3
"""retronet-proxy — the corpus-only HTTP/1.0 forward proxy of the web plane.

Runs INSIDE the gateway CT (951, 10.99.0.2). An era browser sets one thing —
its HTTP proxy to 10.99.0.2:3128 — and browses a 1990s web served entirely from
a local corpus, with a search service over it.

THE SECURITY PROPERTY, in one sentence: this program NEVER opens a connection to
the real internet. There is no upstream fetch, no DNS lookup, no fallback. A
request for a host that is not in the corpus returns a period "not in the
museum's internet" 404 page — it does not touch the network. The ONLY outbound
connection this program can make is to the CT-local search backend
(default 127.0.0.1:8090), made in exactly one function (`forward_to_search`);
everything else is local file I/O. The CT also has no default route (see
docs/lab/retronet/GATEWAY.md), so even a bug here has nowhere to send a packet.

HTTP/1.0 by construction: every response is HTTP/1.0 with an explicit
Content-Length and Connection: close — no chunked transfer, no gzip — which is
what era browsers (Netscape 4, IE5) expect from a proxy.

Config (systemd EnvironmentFile /etc/retronet/proxy.env, or the environment):
  RN_PROXY_LISTEN          bind address host:port       (default 10.99.0.2:3128)
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

# --- defaults (every one overridable from /etc/retronet/proxy.env) -----------
DEF_LISTEN = "10.99.0.2:3128"
DEF_CORPUS = "/data/retronet/corpus"
DEF_SEARCH_HOSTS = "search.retronet"
DEF_SEARCH_BACKEND = "127.0.0.1:8090"

# The corpus is downgraded to Latin-1 (see WEB-PLANE-PLAN.md), so text types are
# labelled accordingly rather than left to a browser's guess.
TEXT_CHARSET = "iso-8859-1"

# Era-correct content types by extension. mimetypes fills any gap; the final
# fallback is application/octet-stream. No modern types are needed — the corpus
# is HTML 3.2 + GIF/JPEG.
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
}
TEXT_TYPES = {"text/html", "text/plain", "text/css"}

# A hostname we are willing to serve as a corpus directory. Anything else is a
# malformed request, never a filesystem path.
HOST_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")


def content_type(path: str) -> str:
    ext = os.path.splitext(path)[1].lower()
    ctype = CONTENT_TYPES.get(ext)
    if ctype is None:
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
    if ctype in TEXT_TYPES:
        ctype += f"; charset={TEXT_CHARSET}"
    return ctype


def era_page(title: str, heading: str, paras: list[str]) -> bytes:
    """A tiny HTML 3.2 page, Latin-1, in the spirit of a 1990s server notice."""
    body = "\n".join(f"<P>{p}</P>" for p in paras)
    html = (
        '<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 3.2 Final//EN">\n'
        f"<HTML><HEAD><TITLE>{title}</TITLE></HEAD>\n"
        '<BODY BGCOLOR="#FFFFFF" TEXT="#000000" LINK="#0000EE" VLINK="#551A8B">\n'
        f"<H1>{heading}</H1>\n{body}\n<HR>\n"
        "<ADDRESS>retronet proxy &#151; an offline museum of the 1990s web. "
        "No live internet.</ADDRESS>\n</BODY></HTML>\n"
    )
    return html.encode(TEXT_CHARSET, "replace")


class ProxyServer(ThreadingHTTPServer):
    """One instance, shared across handler threads. Holds the immutable config
    and a cheap mtime-checked cache of the corpus manifest (sites.json)."""

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, addr, corpus_root, search_hosts, search_backend):
        super().__init__(addr, ProxyHandler)
        self.corpus_root = os.path.realpath(corpus_root)
        self.search_hosts = frozenset(h.lower() for h in search_hosts)
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
        self.send_response(200)
        self.send_header("Content-Type", content_type(target))
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
        otherwise it says 'this host is not on the retronet at all'."""
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
        self.send_era(404, "404 Not Found", "Not in the Museum's Internet", paras)

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
    def send_era(self, code, title, heading, paras):
        data = era_page(title, heading, paras)
        self.send_response(code)
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
    corpus = os.environ.get("RN_PROXY_CORPUS", DEF_CORPUS)
    hosts = os.environ.get("RN_PROXY_SEARCH_HOSTS", DEF_SEARCH_HOSTS)
    backend = os.environ.get("RN_PROXY_SEARCH_BACKEND", DEF_SEARCH_BACKEND)
    bind_host, bind_port = split_hostport(listen, 3128)
    search_hosts = [h for h in re.split(r"[,\s]+", hosts) if h]
    backend_host, backend_port = split_hostport(backend, 8090)
    return {
        "addr": (bind_host, bind_port),
        "corpus": corpus,
        "search_hosts": search_hosts,
        "search_backend": (backend_host, backend_port),
    }


def main():
    cfg = load_config()
    os.makedirs(cfg["corpus"], exist_ok=True)
    server = ProxyServer(cfg["addr"], cfg["corpus"], cfg["search_hosts"], cfg["search_backend"])
    host, port = cfg["addr"]
    hosts = ",".join(sorted(server.search_hosts)) or "(none)"
    backend = f"{server.search_backend[0]}:{server.search_backend[1]}"
    sys.stderr.write(
        f"retronet-proxy: listening on {host}:{port}  corpus={server.corpus_root}  search={hosts} -> {backend}\n"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()

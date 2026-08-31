#!/usr/bin/env python3
"""osgallery-https-server.py

Single-origin HTTPS server for the Kernel Hive SPA that gives the browser a
SECURE CONTEXT (required for WebTransport / WebCodecs) and, from the SAME
ORIGIN, the per-tile streamhost signaling JSON.

Serves:
  GET /                         -> SPA index.html (dist)
  GET /assets/... , /*.png ...  -> static files from WEBROOT (SPA build)
  GET /<client-route>           -> SPA fallback to index.html (no dot in path)
  GET /signal/<tile>.json       -> {"host","udpPort","certHashB64"} read LIVE
                                   from the tile's streamhost cert-hash file, so
                                   cert ROTATION is picked up with no restart.
  POST /webrtc/<tile>/offer     -> platform non-trickle SDP proxy; every tile in
                                   SIGNAL_CONFIG is routed to one generic bridge.
  GET /signal/index.json        -> list of configured tiles + their udpPort
  GET/POST /walkin/*            -> the walk-in plane (walkin_plane.py): the public
                                   pool state, passkey signup, and ONE private
                                   clone per visitor. Absent — every route 404s
                                   into the SPA fallback — unless WALKIN_REGISTRY
                                   names a directory. Who may reach it is the
                                   /admin switch's answer, floored by WALKIN_OPEN.
  GET /healthz                  -> "ok"
  POST /restore/<osId>          -> reset ONE tile to its golden fixture (no token —
                                   LAN-gated + non-destructive): runs reset-tile.sh <osId>,
                                   which does a live QMP `loadvm golden` or a
                                   cold-boot restart per golden-manifest.json.
                                   Wired to StreamView's "Restore to golden" button.
  POST /clientlog               -> untokened browser telemetry sink, open to EVERY session
                                   (the visitor whose stream failed is the one whose
                                   telemetry matters most). Body is one
                                   JSON event object or an ARRAY of events; each
                                   is appended as one JSONL line (+srvTs, +ip) to
                                   CLIENTLOG (clientlog.jsonl). Retention is a
                                   ROLLING WINDOW (CLIENTLOG_RETENTION_SECS,
                                   default 36 h) pruned by age, with
                                   CLIENTLOG_MAX as a runaway size backstop.
  GET  /clientcmd?since=<seq>   -> command polling for ANY authenticated gallery
                                   session (the READ half). Every visitor tab
                                   registers and is reachable, so any session can
                                   be debugged. Re-reads CLIENTCMD (clientcmd.json)
                                   fresh per request, returns only cmds seq > since.
                                   Polling reads the queue; it confers nothing.
  POST /clientcmd/admin         -> enqueue a command (the WRITE half) — BOX-SIDE
                                   ONLY: refused outright on the public listener
                                   (auth/gate.py BLOCKED_PREFIXES) and, on this
                                   one, requires a LOOPBACK peer plus a valid
                                   X-Admin-Token (CLIENTCMD_TOKEN, read fresh per
                                   request). No UI session can issue a command.
                                   Atomic tmp+replace write, queue trimmed to the
                                   last 100 cmds. Every accepted command is
                                   appended to CLIENTCMD_AUDIT. The eval command
                                   runs arbitrary JavaScript in the targeted
                                   browser and needs no further opt-in — set
                                   OSG_ADMIN_EVAL=0 to disable it.

Everything is TLS-wrapped with a cert the user's Chrome trusts (the local CA
leaf from gen-local-ca.sh). CORS is permissive so a throwaway test page on
another localhost origin can also read /signal/*.json during bring-up.

Config: a tiles JSON file (SIGNAL_CONFIG), mapping tile-id -> deploy info. WebRTC
is deliberately NOT configured here: it is a platform capability for every key.
  {
    "reactos": { "udpPort": 4433, "hashFile": "/data/vms/streamhost/run951/cert_hash_b64.txt" },
    "win95": { "udpPort": 54091, "hashFile": "/data/vms/streamhost/stations/win95/cert_hash_b64.txt" }
  }

Env (all optional except paths):
  WEBROOT        dir of the built SPA (contains index.html)         [required]
  SIGNAL_CONFIG  path to tiles JSON                                  [required]
  BIND_IP        listen address                       (default 0.0.0.0)
  PORT           listen port                           (default 8443)
  CERT           TLS cert (leaf or fullchain) PEM                    [required]
  KEY            TLS private key PEM                                 [required]
  SIGNAL_HOST    host value put in signaling JSON      (default 192.0.2.10)
  WEBRTC_BRIDGE_UPSTREAM one generic loopback bridge base (default http://127.0.0.1:18080)
  WEBRTC_ICE_SERVERS_FILE platform ICE JSON (default <server dir>/webrtc-ice-servers.json)
  CLIENTLOG      telemetry JSONL path        (default <server dir>/clientlog.jsonl)
  CLIENTLOG_MAX  size backstop in bytes                       (default 67108864)
  CLIENTLOG_RETENTION_SECS rolling telemetry window in seconds   (default 129600)
  CLIENTCMD      command queue JSON path      (default <server dir>/clientcmd.json)
  CLIENTCMD_TOKEN admin token file    (default <server dir>/pki/clientcmd.token)
  CLIENTCMD_AUDIT issued-command audit trail (default <server dir>/clientcmd-audit.jsonl)
  USAGE_STATS    interaction-counter file     (default <server dir>/usage-stats.json)
  OSG_ADMIN_EVAL set to 0 to DISABLE arbitrary-JS eval commands   (default on)
  WALKIN_REGISTRY registry/walkin dir     (default /data/kernel-hive/registry/walkin)
  WALKIN_REPO    repo root the launcher paths resolve against (default /data/kernel-hive)
  WALKIN_TICK_SECS pool watchdog interval in seconds               (default 15)
  WALKIN_OPEN    walk-in env FLOOR; unset/0 = closed whatever the switch says
  WALKIN_ARP_PRIME the plane's ARP-priming helper, a `{ip}` command template

The route bodies live beside their config/globals in dedicated modules
(static_files.py, webrtc.py, clientlog.py, clientcmd.py, restore.py,
signal_route.py, usage.py, config.py) — this file is the HTTP handler skeleton
(framing, CORS, auth gating, keep-alive) plus do_GET/do_POST dispatch to
them.
"""

import contextlib
import ipaddress
import json
import ssl
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

# The auth package sits beside this file, which systemd starts by absolute path
# rather than as a module, so its directory is not on sys.path by default.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import clientcmd  # noqa: E402
import clientlog  # noqa: E402
import deploy_hint  # noqa: E402
import restore  # noqa: E402
import signal_route  # noqa: E402
import static_files  # noqa: E402
import usage  # noqa: E402
import walkin_plane  # noqa: E402  (the walk-in seams; contract ledger §3.1)
import webrtc  # noqa: E402
from auth import gate  # noqa: E402  (import needs the sys.path line above)
from auth import routes as auth_routes  # noqa: E402
from auth.service import AuthService  # noqa: E402
from config import (  # noqa: E402
    AUTH_STATE,
    BIND_IP,
    CERT,
    KEY,
    OSG_ADMIN_EVAL,
    PORT,
    PUBLIC_BIND,
    PUBLIC_HOST,
    PUBLIC_ORIGIN,
    PUBLIC_PORT,
    SIGNAL_CONFIG,
    SIGNAL_HOST,
    STREAM_KEY_FILE,
    USAGE_STATS,
    WEBROOT,
)
from static_files import MIME  # noqa: E402

# Both filled in by main() when the public listener is enabled; the request
# handlers reach them as module globals.
AUTH = None
STREAM_KEY = b""
# Interaction counters. Unlike AUTH this exists on BOTH listeners: a station's
# usage total is a fact about the machine, and the lab's own LAN traffic is as
# real a use of it as a visitor's. Only the per-PERSON half needs a session, and
# that half lives behind /auth/usage/report.
USAGE = usage.UsageStore(USAGE_STATS)


# The deploy trigger (docs/lab/CONTINUOUS-DEPLOY-PROPOSAL.md §1.1). Its entire
# side effect is bumping one file's mtime; it runs no git operation, spawns no
# process, and CANNOT say what to deploy. The reconciler fetches origin/main
# itself and converges to what IT finds.
#
# UNARMED UNLESS BOTH SECRETS ARE PRESENT ON THE BOX. Keys are read from
# root-only files outside the repo — never from anything the repo carries, and
# never from an env var that could reach a log. With no key the receiver answers
# 503 to everything, which is the correct default for a public deploy trigger:
# the closed state is the one you get by doing nothing.
def _deploy_secret(name: str) -> bytes:
    path = Path(f"/etc/kh/{name}")
    try:
        if path.stat().st_mode & 0o077:
            return b""  # group/other-readable: refuse rather than trust it
        return path.read_bytes().strip()
    except OSError:
        return b""


DEPLOY_HINT = deploy_hint.HintReceiver(
    keys={
        "webhook": _deploy_secret("deploy-webhook-secret"),
        "actions": _deploy_secret("deploy-actions-secret"),
    },
    wakeup=Path("/data/vms/streamhost/.kh-reconciler/wakeup"),
)


class H(BaseHTTPRequestHandler):
    server_version = "osgallery-https/1.0"
    # HTTP/1.1 = persistent connections. The grid fetches 60+ poster thumbnails
    # and a station page a dozen hashed assets; under HTTP/1.0 (the stdlib
    # default) every one of those was a fresh TCP + TLS handshake, which is
    # what made the grid visibly reload on every navigation. Every response
    # this server writes is Content-Length framed (_send, the 206/416 paths,
    # auth _reply), which is what keep-alive requires; a request whose body we
    # may not have consumed closes the connection instead (do_POST / do_GET).
    protocol_version = "HTTP/1.1"
    # Reap idle keep-alive connections so parked threads don't accumulate.
    timeout = 75
    # Overridden by PublicH. Gates the auth check, the signaling rewrite and CORS.
    public = False

    def _cors(self):
        # Never on the public listener: a wildcard origin there would invite
        # any site to read this authenticated one's responses.
        if self.public:
            return
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _send(self, code, body, ctype, cache=True, extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        # Permissions-Policy: explicitly grant the Fullscreen API to this origin.
        # The top-level document is allowed to use fullscreen by default, but
        # stating it makes the grant self-documenting and immune to any future
        # embedding/proxying that would otherwise disable it (the UI's Fullscreen
        # button requestFullscreen()s from a direct user gesture).
        if ctype.startswith("text/html"):
            self.send_header("Permissions-Policy", "fullscreen=(self)")
        if not cache:
            self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self):
        self.do_GET()

    def _read_json_body(self, cap):
        """Read + parse a JSON request body: returns (obj, None) on success or
        (None, (code, msg)) on failure. Content-Length is the ONLY supported
        framing — BaseHTTPRequestHandler does not decode chunked transfer
        coding, so chunked requests are rejected outright."""
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            return None, (411, "chunked transfer coding not supported; send Content-Length")
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return None, (411, "bad Content-Length")
        if n <= 0:
            return None, (411, "Content-Length required")
        if n > cap:
            # Drain (bounded) before replying so the close after our 413 is
            # orderly instead of a mid-upload reset.
            with contextlib.suppress(OSError):
                self.rfile.read(min(n, 4 * cap))
            return None, (413, f"body exceeds {cap} bytes")
        raw = b""
        while len(raw) < n:
            chunk = self.rfile.read(n - len(raw))
            if not chunk:
                break
            raw += chunk
        try:
            return json.loads(raw.decode("utf-8")), None
        except Exception:
            return None, (400, "invalid JSON")

    def read_json_body(self, cap):
        """Public alias of _read_json_body for the auth routes module."""
        return self._read_json_body(cap)

    def _public_gate(self, path: str) -> bool:
        """Public listener only: decide whether this request may proceed.

        Returns True to continue into the ordinary routing. Anything else has
        already been answered here.
        """
        if gate.is_blocked(path):
            self._send(404, json.dumps({"error": "not found"}), MIME[".json"], cache=False)
            return False
        if gate.is_open(path):
            return True
        user = AUTH.user_for_token(auth_routes.session_token(self))
        # Signed in is enough for an INVITED session — that is what gate.allows
        # returns for every role but one, and the invited plane is unchanged. A
        # walk-in is the exception: an anonymous stranger's fence is an
        # allowlist whose one interactive surface is their OWN clone, so the
        # gate is told which clone that is.
        if user and gate.allows(path, user, walkin_plane.own_signal(user)):
            return True
        if gate.wants_html(self.headers.get("Accept")):
            # A browser typing the hostname in should land on a page it can act
            # on, not a bare 401 — and for a walk-in that page is the walk-in
            # landing, never the invited plane's login screen.
            self.send_response(302)
            self.send_header("Location", gate.landing_for(user))
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return False
        code, message = (403, "not yours") if user else (401, "sign in first")
        self._send(code, json.dumps({"error": message}), MIME[".json"], cache=False)
        return False

    def _require_session(self, surface: str) -> bool:
        """Authenticate the READ half of the command plane: the poll a tab makes.

        Remote debugging must work for EVERY session, always — the visitor whose
        stream is broken is exactly the one worth reaching, and they are never an
        operator. So any authenticated gallery session may poll. The LAN listener
        stays open exactly as it has always been (it is the lab's own network and
        every lab script depends on it), which makes the poll behave precisely
        like /clientlog: untokened on LAN, session-gated on the public edge.

        This grants no authority: polling only READS the operator's queue, and a
        tab acts on a command only when that command is addressed to it. Issuing
        one remains _require_box_side's job, and that is box-side only.
        """
        if not self.public:
            return True
        if clientcmd._clientcmd_token_ok(self.headers.get("X-Admin-Token")):
            return True
        if AUTH and AUTH.user_for_token(auth_routes.session_token(self)):
            return True
        self._send(401, json.dumps({"error": "sign in first"}), MIME[".json"], cache=False)
        return False

    def _admin_identity(self):
        """Who authorized this enqueue, for the audit record — never a secret.

        Returns a short string or None if the request is not authorized. The
        operator token is NEVER echoed: only the fact that a valid one was
        presented, and the loopback peer it came from.
        """
        if not self._peer_is_loopback():
            return None
        if clientcmd._clientcmd_token_ok(self.headers.get("X-Admin-Token")):
            return f"token@{self.client_address[0] if self.client_address else 'local'}"
        return None

    def _peer_is_loopback(self) -> bool:
        """Whether this request came from the box itself.

        MUST NOT be used on the public listener, and refuses to be: that
        listener is bound to loopback with the edge tunnel proxying into it, so
        EVERY peer there is 127.0.0.1 and this would answer True for a visitor
        on the other side of the world. On the LAN listener the peer is real.
        The enqueue path is 404'd on the public listener before routing anyway
        (gate.BLOCKED_PREFIXES); this is the belt to that braces.
        """
        if self.public:
            return False
        peer = self.client_address[0] if self.client_address else ""
        try:
            return ipaddress.ip_address(peer).is_loopback
        except ValueError:
            return False

    def _require_box_side(self, surface: str) -> bool:
        """Guard the ENQUEUE: it is a box-side act, not a browser-reachable one.

        Two independent conditions, both required. The peer must be loopback —
        so nothing a browser can reach, on any listener, can issue a command —
        and the operator token must be presented as defence in depth. The public
        listener never gets here at all: gate.BLOCKED_PREFIXES 404s the path
        before routing. `clientcmd.sh` posts to https://127.0.0.1:8443, so the
        operator's workflow is unchanged.
        """
        if self._admin_identity() is not None:
            return True
        client = self.client_address[0] if self.client_address else "unknown"
        reason = "non-loopback peer" if not self._peer_is_loopback() else "bad/missing token"
        sys.stderr.write(f"[serve] {surface} DENIED ({reason}, peer={client})\n")
        self._send(404, json.dumps({"error": "not found"}), MIME[".json"], cache=False)
        return False

    def do_POST(self):
        path = unquote(urlparse(self.path).path)
        # POSTs are rare (auth, one clientlog batch, restore, WebRTC offer) and
        # several branches reply before reading the body — under keep-alive an
        # unread body would be parsed as the NEXT request. Close after every
        # POST; only the GET-heavy static/thumbnail traffic needs persistence.
        self.close_connection = True

        if self.public:
            if auth_routes.dispatch(self, path, "POST", AUTH, PUBLIC_ORIGIN):
                return
            if not self._public_gate(path):
                return
            if walkin_plane.dispatch(self, path, "POST", AUTH, PUBLIC_ORIGIN):
                return

        # Platform WebRTC signaling: every known station routes to the ONE
        # generic bridge by station id (see webrtc.handle_offer).
        if path.startswith("/webrtc/") and path.endswith("/offer"):
            tile = path[len("/webrtc/") : -len("/offer")].strip("/")
            return webrtc.handle_offer(self, tile, signal_route.load_tiles)

        # POST /clientlog — untokened LAN/VPN telemetry sink (clientlog.handle_post).
        if path == "/clientlog":
            return clientlog.handle_post(self)

        # POST /usage — one tab's click/keystroke tally (serve/usage.py).
        if path == "/usage":
            # The public listener has already required a session (_public_gate);
            # here we additionally require the report to have been sent BY the
            # gallery, so no other site can spend a visitor's cookie inflating
            # their score. The LAN listener has neither notion and needs neither.
            if self.public and self.headers.get("Origin") != PUBLIC_ORIGIN:
                return self._send(403, json.dumps({"error": "bad origin"}), MIME[".json"], cache=False)
            user = AUTH.user_for_token(auth_routes.session_token(self)) if (self.public and AUTH) else None
            return usage.handle_post(self, USAGE, user["id"] if user else None)

        # POST /kh/deploy-hint — the deploy trigger (§1.1). Verifies a GitHub
        # signature and bumps one file's mtime. It cannot name what to deploy,
        # so a forged or replayed request costs one extra fetch of origin/main
        # and nothing else. Deliberately OUTSIDE the public gate: authorisation
        # is write access to the repo, proved by the HMAC, not a visitor session.
        if path == "/kh/deploy-hint":
            return deploy_hint.handle_post(self, DEPLOY_HINT)

        # POST /clientcmd/admin — enqueue a command for polling UI tabs.
        if path == "/clientcmd/admin":
            if not self._require_box_side("clientcmd enqueue"):
                return
            return clientcmd.handle_admin_post(self, self._admin_identity())

        # POST /restore/<osId> — reset ONE station to its golden fixture.
        if path.startswith("/restore/"):
            osid = path[len("/restore/") :].strip("/")
            return restore.handle_restore(self, osid)

        return self._send(404, json.dumps({"error": "not found"}), MIME[".json"], cache=False)

    def do_GET(self):
        path = unquote(urlparse(self.path).path)
        # A GET carrying a body is never read here; don't let it poison the
        # keep-alive stream (see do_POST).
        if self.headers.get("Content-Length") or self.headers.get("Transfer-Encoding"):
            self.close_connection = True

        if self.public:
            if auth_routes.dispatch(self, path, "GET", AUTH, PUBLIC_ORIGIN):
                return
            if not self._public_gate(path):
                return
            if walkin_plane.dispatch(self, path, "GET", AUTH, PUBLIC_ORIGIN):
                return
            if path in ("/login", "/admin", "/account", "/link") or path.startswith("/ui/"):
                return static_files.serve_auth_ui(self, path)

        if path == "/healthz":
            return self._send(200, "ok\n", "text/plain", cache=False)

        # GET /clientcmd?since=<seq> — authenticated operator-tab command polling.
        if path == "/clientcmd":
            if not self._require_session("clientcmd poll"):
                return
            qs = parse_qs(urlparse(self.path).query)
            return clientcmd.handle_poll(self, qs.get("since", ["0"]))

        # GET /usage/stations.json — per-station totals, no identities in it.
        if path == "/usage/stations.json":
            return usage.serve_stations(self, USAGE)

        if path == "/signal/index.json":
            return signal_route.serve_index(self)

        if path.startswith("/signal/") and path.endswith(".json"):
            tile = path[len("/signal/") : -len(".json")]
            return signal_route.serve_tile(self, tile, STREAM_KEY)

        # ---- static UI ----
        return static_files.serve_static(self, path)

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[serve] {self.address_string()} - {fmt % args}\n")


class PublicH(H):
    """The edge-facing handler: same routes, no implicit trust. See auth/gate.py."""

    public = True


def _start_public_listener():
    """Bring up the loopback listener the edge tunnel proxies to, if configured.

    Returns the server (already serving on its own thread) or None. Any failure
    here is fatal rather than degraded: a public listener that came up WITHOUT
    its auth state would be an open gallery, which is worse than no gallery.
    """
    global AUTH, STREAM_KEY
    if not PUBLIC_PORT:
        return None
    if not PUBLIC_HOST:
        sys.stderr.write("[serve] FATAL: PUBLIC_PORT is set but PUBLIC_HOST is empty\n")
        sys.exit(1)

    AUTH = AuthService(AUTH_STATE, rp_id=PUBLIC_HOST, rp_name="OS gallery", origin=PUBLIC_ORIGIN, usage=USAGE)
    token = AUTH.ensure_bootstrap()
    if token:
        # Printed once, to the server log, because it is the only way in until
        # somebody redeems it. It is stored as a hash, so this is genuinely the
        # last chance to read it.
        sys.stderr.write(f"[serve] BOOTSTRAP TOKEN (one-time, admin): {token}\n")

    try:
        STREAM_KEY = STREAM_KEY_FILE.read_bytes().strip()
    except OSError:
        STREAM_KEY = b""
    if not STREAM_KEY:
        sys.stderr.write(
            f"[serve] WARNING: no stream-ticket key at {STREAM_KEY_FILE} — public signaling will omit the\n"
            "[serve]          session ticket, so tiles must not have SH_SESSION_KEY set yet.\n"
        )

    srv = ThreadingHTTPServer((PUBLIC_BIND, PUBLIC_PORT), PublicH)
    threading.Thread(target=srv.serve_forever, daemon=True, name="public-listener").start()
    sys.stderr.write(
        f"[serve] public listener http://{PUBLIC_BIND}:{PUBLIC_PORT}/ -> {PUBLIC_ORIGIN} "
        f"(auth state {AUTH_STATE}, ticket {'on' if STREAM_KEY else 'OFF'})\n"
    )
    return srv


def main():
    if not (WEBROOT / "index.html").is_file():
        sys.stderr.write(f"[serve] FATAL: no index.html under WEBROOT={WEBROOT}\n")
        sys.exit(1)
    _start_public_listener()
    walkin_plane.start(AUTH)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=CERT, keyfile=KEY)
    httpd = ThreadingHTTPServer((BIND_IP, PORT), H)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    sys.stderr.write(
        f"[serve] https://{SIGNAL_HOST}:{PORT}/  webroot={WEBROOT}  "
        f"signal={SIGNAL_CONFIG}  admin_eval={'ON' if OSG_ADMIN_EVAL else 'off'}\n"
    )
    with contextlib.suppress(KeyboardInterrupt):
        httpd.serve_forever()


if __name__ == "__main__":
    main()

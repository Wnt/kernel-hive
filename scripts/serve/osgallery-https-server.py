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
  GET /healthz                  -> "ok"
  POST /restore/<osId>          -> reset ONE tile to its golden fixture (no token —
                                   LAN-gated + non-destructive): runs reset-tile.sh <osId>,
                                   which does a live QMP `loadvm golden` or a
                                   cold-boot restart per golden-manifest.json.
                                   Wired to StreamView's "Restore to golden" button.
  POST /clientlog               -> untokened LAN/VPN browser telemetry sink. Body is one
                                   JSON event object or an ARRAY of events; each
                                   is appended as one JSONL line (+srvTs, +ip) to
                                   CLIENTLOG (clientlog.jsonl, 4 MiB rotation to
                                   a single .1 generation).
  GET  /clientcmd?since=<seq>   -> authenticated command polling for operator SPA tabs. Re-reads
                                   CLIENTCMD (clientcmd.json) fresh per request
                                   and returns only cmds with seq > since.
  POST /clientcmd/admin         -> enqueue a command (X-Admin-Token
                                   header checked against CLIENTCMD_TOKEN, read
                                   fresh per request). Atomic tmp+replace write,
                                   queue trimmed to the last 100 cmds.
                                   The eval command runs arbitrary JavaScript in
                                   every authenticated TARGETED browser; scope it by
                                   tile and args.sessionId. It is rejected unless
                                   OSG_ADMIN_EVAL=1 is set explicitly.

Everything is TLS-wrapped with a cert the user's Chrome trusts (the local CA
leaf from gen-local-ca.sh). CORS is permissive so a throwaway test page on
another localhost origin can also read /signal/*.json during bring-up.

Config: a tiles JSON file (SIGNAL_CONFIG), mapping tile-id -> deploy info. WebRTC
is deliberately NOT configured here: it is a platform capability for every key.
  {
    "reactos": { "udpPort": 4433, "hashFile": "/data/vms/streamhost/run951/cert_hash_b64.txt" },
    "win95": { "udpPort": 54091, "hashFile": "/data/vms/streamhost/tiles/win95/cert_hash_b64.txt" }
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
  CLIENTLOG_MAX  rotate threshold in bytes                     (default 4194304)
  CLIENTCMD      command queue JSON path      (default <server dir>/clientcmd.json)
  CLIENTCMD_TOKEN admin token file    (default <server dir>/pki/clientcmd.token)
  OSG_ADMIN_EVAL enable arbitrary-JS eval commands                (default 0)
"""

import contextlib
import hmac
import json
import os
import ssl
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, unquote, urlparse
from urllib.request import Request, urlopen

# The auth package sits beside this file, which systemd starts by absolute path
# rather than as a module, so its directory is not on sys.path by default.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from auth import gate, tickets  # noqa: E402  (import needs the sys.path line above)
from auth import routes as auth_routes  # noqa: E402
from auth.service import AuthService  # noqa: E402

WEBROOT = Path(os.environ["WEBROOT"]).resolve()
SIGNAL_CONFIG = Path(os.environ["SIGNAL_CONFIG"]).resolve()
BIND_IP = os.environ.get("BIND_IP", "0.0.0.0")
PORT = int(os.environ.get("PORT", "8443"))
CERT = os.environ["CERT"]
KEY = os.environ["KEY"]
SIGNAL_HOST = os.environ.get("SIGNAL_HOST", "192.0.2.10")

# --- public listener (the edge tunnel) ---------------------------------------
# A SECOND listener, plaintext on loopback, that the forwarder-agent proxies
# gallery.example.com to. It shares this process (and therefore the stations,
# the cert-hash files and the restore plumbing) with the LAN HTTPS listener, but
# NOT its trust model: every request on it goes through auth/gate.py first, and
# its signaling doc advertises the public relay host plus a signed stream ticket
# instead of the LAN IP. Unset PUBLIC_PORT and none of it exists.
PUBLIC_PORT = int(os.environ.get("PUBLIC_PORT", "0") or 0)
PUBLIC_BIND = os.environ.get("PUBLIC_BIND", "127.0.0.1")
PUBLIC_HOST = os.environ.get("PUBLIC_HOST", "")
PUBLIC_ORIGIN = os.environ.get("PUBLIC_ORIGIN", f"https://{PUBLIC_HOST}" if PUBLIC_HOST else "")
AUTH_STATE = Path(os.environ.get("AUTH_STATE", str(Path(__file__).resolve().parent / "auth-state.json")))
AUTH_UI = Path(os.environ.get("AUTH_UI", str(Path(__file__).resolve().parent / "authui")))
# Shared with every streamhost unit as SH_SESSION_KEY. Read once at startup:
# rotating it means restarting both sides anyway.
STREAM_KEY_FILE = Path(
    os.environ.get("STREAM_KEY_FILE", str(Path(__file__).resolve().parent / "pki" / "stream-ticket.key"))
)
# Standalone pages the auth plane serves, outside the UI bundle.
_AUTH_PAGES = {
    "/login": "login.html",
    "/admin": "admin.html",
    "/account": "account.html",
    "/link": "link.html",
}
# Both filled in by main() when the public listener is enabled; the request
# handlers reach them as module globals.
AUTH = None
STREAM_KEY = b""

# --- POST /restore/<osId> : reset-to-golden button endpoint ------------------
# The single authority (reset-tile.sh + golden-manifest.json) shared with the
# Playwright input suite's reset-before-run. Defaults sit beside this server so a
# production deploy needs no test dir. Token-gated + non-destructive by construction.
RESET_SCRIPT = Path(os.environ.get("RESET_SCRIPT", str(Path(__file__).resolve().parent / "reset-tile.sh")))
GOLDEN_MANIFEST = Path(os.environ.get("GOLDEN_MANIFEST", str(Path(__file__).resolve().parent / "golden-manifest.json")))
# Restore is enabled by default; set RESTORE_ENABLE=0 to disable the endpoint.
RESTORE_ENABLE = os.environ.get("RESTORE_ENABLE", "1") not in ("0", "false", "no")

# --- client observability: /clientlog + /clientcmd ---------------------------
# Telemetry sink + command queue for the UI (Firefox decoder debugging et al).
# All files sit beside this server by default so a production deploy needs no
# extra config; every one is (re-)read or appended per request — no restart
# needed after hand-edits, and restart-https.sh's log truncation never touches
# clientlog.jsonl.
CLIENTLOG = Path(os.environ.get("CLIENTLOG", str(Path(__file__).resolve().parent / "clientlog.jsonl")))
CLIENTLOG_MAX = int(os.environ.get("CLIENTLOG_MAX", str(4 * 1024 * 1024)))
CLIENTLOG_BODY_MAX = 16 * 1024  # request-body cap (shared by /clientcmd/admin)
WEBRTC_OFFER_BODY_MAX = 128 * 1024
WEBRTC_BRIDGE_UPSTREAM = os.environ.get("WEBRTC_BRIDGE_UPSTREAM", "http://127.0.0.1:18080").rstrip("/")
WEBRTC_ICE_SERVERS_FILE = Path(
    os.environ.get(
        "WEBRTC_ICE_SERVERS_FILE",
        str(Path(__file__).resolve().parent / "webrtc-ice-servers.json"),
    )
)
CLIENTCMD = Path(os.environ.get("CLIENTCMD", str(Path(__file__).resolve().parent / "clientcmd.json")))
CLIENTCMD_TOKEN = Path(
    os.environ.get("CLIENTCMD_TOKEN", str(Path(__file__).resolve().parent / "pki" / "clientcmd.token"))
)
CLIENTCMD_ALLOWED = ("snapshot", "verbose", "reload", "eval")
CLIENTCMD_KEEP = 100  # queue trimmed to the last N commands

# --- ADMIN SECURITY BOUNDARY -------------------------------------------------
# The edge tunnel can make public visitors appear to have an RFC1918 socket
# peer, so client_address is telemetry only and NEVER authorization. Every
# operator/observability endpoint requires the file-backed X-Admin-Token; public
# UI/static/signaling/WebRTC routes do not. Arbitrary-JS eval has a second,
# default-off switch so possession of the token alone cannot enable it.
OSG_ADMIN_EVAL = os.environ.get("OSG_ADMIN_EVAL", "0").strip().lower() in (
    "1",
    "true",
    "yes",
    "on",
)
# One lock guards clientlog append/rotate AND clientcmd read-modify-write:
# ThreadingHTTPServer runs one thread per connection, so both are concurrent.
_log_lock = threading.Lock()

# Whitelisted client-supplied event fields -> stored key. The client's "ts"
# is stored as "clientTs" so it can never shadow the server-side timestamp.
_CLIENTLOG_FIELDS = (
    ("ts", "clientTs"),
    ("clientTs", "clientTs"),
    ("sessionId", "sessionId"),
    ("tile", "tile"),
    ("ua", "ua"),
    ("event", "event"),
    ("detail", "detail"),
    ("message", "message"),
    ("stack", "stack"),
    ("source", "source"),
    ("lineno", "lineno"),
    ("colno", "colno"),
    ("href", "href"),
    ("componentStack", "componentStack"),
)
_CLIENTLOG_STR_MAX = 512  # per-field truncation (detail, ua, ...)
_CLIENTLOG_LONG_FIELDS = frozenset(("stack", "componentStack"))
_CLIENTLOG_LONG_STR_MAX = 4096


def _webrtc_ice_servers():
    """Read platform ICE servers without ever logging credential contents."""
    try:
        doc = json.loads(WEBRTC_ICE_SERVERS_FILE.read_text())
        servers = doc.get("iceServers") if isinstance(doc, dict) else doc
        return servers if isinstance(servers, list) else []
    except FileNotFoundError:
        # Host/UDP is intentional while TURN is unavailable; absence is quiet.
        return []
    except Exception as e:
        sys.stderr.write(f"[serve] WebRTC ICE config unavailable ({type(e).__name__})\n")
        return []


def _restore_osids() -> set:
    """The osIds the button may restore = keys of golden-manifest.json."""
    try:
        return set(json.loads(GOLDEN_MANIFEST.read_text()).get("tiles", {}).keys())
    except Exception as e:
        sys.stderr.write(f"[serve] golden manifest unreadable: {e}\n")
        return set()


def _clientlog_record(ev: dict, client: str) -> dict:
    """One JSONL record: srvTs + ip (server truth) + whitelisted client fields,
    strings truncated so a misbehaving client cannot bloat the log."""
    rec = {"srvTs": round(time.time(), 3), "ip": client}
    for src, dst in _CLIENTLOG_FIELDS:
        v = ev.get(src)
        if v is None:
            continue
        if isinstance(v, str):
            limit = _CLIENTLOG_LONG_STR_MAX if src in _CLIENTLOG_LONG_FIELDS else _CLIENTLOG_STR_MAX
            v = v[:limit]
        elif not isinstance(v, (int, float, bool)):
            v = str(v)[:_CLIENTLOG_STR_MAX]
        rec[dst] = v
    return rec


def _clientlog_append(records):
    """Append records under the lock; rotate a single .1 generation at 4 MiB."""
    with _log_lock:
        try:
            if CLIENTLOG.exists() and CLIENTLOG.stat().st_size > CLIENTLOG_MAX:
                os.replace(CLIENTLOG, CLIENTLOG.with_name(CLIENTLOG.name + ".1"))
        except OSError as e:
            sys.stderr.write(f"[serve] clientlog rotate failed: {e}\n")
        with open(CLIENTLOG, "a", encoding="utf-8") as f:
            for rec in records:
                f.write(json.dumps(rec, separators=(",", ":")) + "\n")


def _clientcmd_load() -> dict:
    """Read the command queue fresh per request (load_tiles() idiom: hand-edits
    over ssh need no restart). Missing/corrupt file == empty queue."""
    try:
        doc = json.loads(CLIENTCMD.read_text())
        if not isinstance(doc, dict):
            raise ValueError("queue root is not an object")
        doc["seq"] = int(doc.get("seq", 0))
        cmds = doc.get("cmds")
        doc["cmds"] = [c for c in cmds if isinstance(c, dict)] if isinstance(cmds, list) else []
        return doc
    except FileNotFoundError:
        return {"seq": 0, "cmds": []}
    except Exception as e:
        sys.stderr.write(f"[serve] clientcmd queue unreadable: {e}\n")
        return {"seq": 0, "cmds": []}


def _clientcmd_save(doc: dict):
    """Atomic write (tmp + os.replace) so pollers never see a torn file."""
    tmp = CLIENTCMD.with_name(CLIENTCMD.name + ".tmp")
    tmp.write_text(json.dumps(doc, separators=(",", ":")))
    os.replace(tmp, CLIENTCMD)


def _clientcmd_token_ok(presented) -> bool:
    """Constant-time check against the token file, read fresh per request.
    Missing/empty token file fails CLOSED (endpoint unusable until minted)."""
    try:
        want = CLIENTCMD_TOKEN.read_text().strip()
    except Exception:
        return False
    if not want or not presented:
        return False
    return hmac.compare_digest(want, presented.strip())


MIME = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
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


def load_tiles():
    """Read the tiles config fresh each request so edits need no restart."""
    try:
        return json.loads(SIGNAL_CONFIG.read_text())
    except Exception as e:
        sys.stderr.write(f"[serve] tiles config unreadable: {e}\n")
        return {}


class H(BaseHTTPRequestHandler):
    server_version = "osgallery-https/1.0"
    # Overridden by PublicH. Gates the auth check, the signaling rewrite and CORS.
    public = False

    def _cors(self):
        # Never on the public listener: a wildcard origin there would invite
        # any site to read this authenticated one's responses.
        if self.public:
            return
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

    def _send(self, code, body, ctype, cache=True):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self._cors()
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
        if user:
            # A few paths need more than "signed in" (the operator command poll).
            if path.startswith(gate.ADMIN_PREFIXES) and user.get("role") != "admin":
                self._send(404, json.dumps({"error": "not found"}), MIME[".json"], cache=False)
                return False
            return True
        if gate.wants_html(self.headers.get("Accept")):
            # A browser typing the hostname in should land on the login screen,
            # not on a bare 401 it cannot act on.
            self.send_response(302)
            self.send_header("Location", "/login")
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return False
        self._send(401, json.dumps({"error": "sign in first"}), MIME[".json"], cache=False)
        return False

    def _require_admin(self, surface: str) -> bool:
        """Authenticate an admin request without treating its peer IP as trust."""
        if _clientcmd_token_ok(self.headers.get("X-Admin-Token")):
            return True
        # On the public listener a passkey ADMIN session stands in for the shared
        # token: it is per-person, revocable and phishing-resistant, where the
        # token is one string shared by every operator tab. Only reached for the
        # paths auth/gate.py lists as admin-reachable (the command poll); the
        # enqueue side is refused before it ever gets here.
        if self.public and AUTH:
            user = AUTH.user_for_token(auth_routes.session_token(self))
            if user and user.get("role") == "admin":
                return True
        client = self.client_address[0] if self.client_address else "unknown"
        sys.stderr.write(f"[serve] {surface} DENIED (bad/missing token, peer={client})\n")
        self._send(403, json.dumps({"error": "bad or missing X-Admin-Token"}), MIME[".json"], cache=False)
        return False

    def do_POST(self):
        path = unquote(urlparse(self.path).path)

        if self.public:
            if auth_routes.dispatch(self, path, "POST", AUTH, PUBLIC_ORIGIN):
                return
            if not self._public_gate(path):
                return

        # Platform WebRTC signaling: every known station routes to the ONE generic
        # bridge by station id. Upstream is global + loopback-only, so tiles.json can
        # never become a per-station proxy/gate. SDP and ICE/TURN credentials are
        # intentionally never written to logs.
        if path.startswith("/webrtc/") and path.endswith("/offer"):
            tile = path[len("/webrtc/") : -len("/offer")].strip("/")
            info = load_tiles().get(tile)
            if not isinstance(info, dict):
                return self._send(404, json.dumps({"error": "unknown tile", "tile": tile}), MIME[".json"], cache=False)
            obj, err = self._read_json_body(WEBRTC_OFFER_BODY_MAX)
            if err:
                return self._send(err[0], json.dumps({"error": err[1]}), MIME[".json"], cache=False)
            if not isinstance(obj, dict) or obj.get("type") != "offer" or not isinstance(obj.get("sdp"), str):
                return self._send(400, json.dumps({"error": "expected SDP offer"}), MIME[".json"], cache=False)
            parsed = urlparse(WEBRTC_BRIDGE_UPSTREAM)
            if (
                parsed.scheme != "http"
                or parsed.hostname not in ("127.0.0.1", "::1", "localhost")
                or parsed.query
                or parsed.fragment
            ):
                return self._send(
                    500, json.dumps({"error": "WebRTC upstream must be loopback HTTP"}), MIME[".json"], cache=False
                )
            upstream = f"{WEBRTC_BRIDGE_UPSTREAM}/offer/{quote(tile, safe='')}"
            try:
                req = Request(
                    upstream,
                    data=json.dumps(obj).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                    method="POST",
                )
                with urlopen(req, timeout=15) as response:
                    body = response.read(WEBRTC_OFFER_BODY_MAX)
                    status = response.status
                sys.stderr.write(f"[serve] WebRTC offer tile={tile} upstream_status={status}\n")
                return self._send(status, body, MIME[".json"], cache=False)
            except HTTPError as e:
                detail = e.read(4096).decode("utf-8", errors="replace")
                sys.stderr.write(f"[serve] WebRTC offer tile={tile} upstream_status={e.code}\n")
                return self._send(e.code, detail, MIME[".json"], cache=False)
            except (URLError, TimeoutError, OSError) as e:
                sys.stderr.write(f"[serve] WebRTC offer tile={tile} upstream_error={type(e).__name__}\n")
                return self._send(
                    502, json.dumps({"error": "WebRTC platform bridge unavailable"}), MIME[".json"], cache=False
                )

        # POST /clientlog — browser telemetry sink. NOT token-gated: this is a
        # LAN/VPN-only deployment, so drag/hover + client diagnostics upload with
        # zero operator setup. Body: one event object or an array (the client
        # batches; HTTP/1.0 close-per-request makes per-event POSTs a TLS handshake
        # each). Appended as JSONL. The operator COMMAND plane (/clientcmd, /clientcmd
        # /admin, eval) stays token-gated below — telemetry ingest is write-only and
        # harmless; remote command/eval is not.
        if path == "/clientlog":
            client = self.client_address[0] if self.client_address else ""
            obj, err = self._read_json_body(CLIENTLOG_BODY_MAX)
            if err:
                return self._send(err[0], json.dumps({"error": err[1]}), MIME[".json"], cache=False)
            events = obj if isinstance(obj, list) else [obj]
            if not events or not all(isinstance(e, dict) for e in events):
                return self._send(
                    400,
                    json.dumps({"error": "expected an event object or an array of event objects"}),
                    MIME[".json"],
                    cache=False,
                )
            _clientlog_append([_clientlog_record(e, client) for e in events])
            return self._send(200, '{"ok":true}', MIME[".json"], cache=False)

        # POST /clientcmd/admin — enqueue a command for polling UI tabs.
        # X-Admin-Token vs $SERVE/pki/clientcmd.token (read fresh per request,
        # like every other config file here). Peer IP is deliberately ignored.
        if path == "/clientcmd/admin":
            if not self._require_admin("clientcmd admin"):
                return
            obj, err = self._read_json_body(CLIENTLOG_BODY_MAX)
            if err:
                return self._send(err[0], json.dumps({"error": err[1]}), MIME[".json"], cache=False)
            if not isinstance(obj, dict):
                return self._send(400, json.dumps({"error": "expected a command object"}), MIME[".json"], cache=False)
            cmd = obj.get("cmd")
            if cmd not in CLIENTCMD_ALLOWED:
                return self._send(
                    400,
                    json.dumps({"error": "unknown cmd", "allowed": list(CLIENTCMD_ALLOWED)}),
                    MIME[".json"],
                    cache=False,
                )
            if cmd == "eval" and not OSG_ADMIN_EVAL:
                return self._send(
                    403,
                    json.dumps({"error": "eval disabled; set OSG_ADMIN_EVAL=1 explicitly"}),
                    MIME[".json"],
                    cache=False,
                )
            tile = obj.get("tile") or "*"
            # Preserve the complete args object unchanged in the queue. In
            # particular, eval requires args.code and optional args.sessionId.
            args = obj.get("args") or {}
            if not isinstance(tile, str) or not isinstance(args, dict):
                return self._send(
                    400, json.dumps({"error": "tile must be a string, args an object"}), MIME[".json"], cache=False
                )
            with _log_lock:
                doc = _clientcmd_load()
                doc["seq"] += 1
                doc["cmds"].append(
                    {"seq": doc["seq"], "ts": round(time.time(), 3), "cmd": cmd, "tile": tile[:64], "args": args}
                )
                doc["cmds"] = doc["cmds"][-CLIENTCMD_KEEP:]
                _clientcmd_save(doc)
                seq = doc["seq"]
            sys.stderr.write(f"[serve] clientcmd enqueued seq={seq} {cmd} tile={tile}\n")
            return self._send(200, json.dumps({"ok": True, "seq": seq}), MIME[".json"], cache=False)

        # POST /restore/<osId> — reset ONE station to its golden fixture. No token
        # required: the endpoint is LAN-gated and non-destructive (reset-tile.sh
        # only loadvm-restores or cold-boots; it never runs savevm), so the
        # exhibit's "Restore to golden" button works for any visitor. The
        # RESTORE_ENABLE switch is the operator's off-lever; the allowed-osId set
        # (golden-manifest keys) bounds which stations it can touch.
        if path.startswith("/restore/"):
            if not RESTORE_ENABLE:
                return self._send(403, json.dumps({"error": "restore disabled"}), MIME[".json"], cache=False)
            osid = path[len("/restore/") :].strip("/")
            allowed = _restore_osids()
            if not osid or osid not in allowed:
                return self._send(404, json.dumps({"error": "unknown osId", "osId": osid}), MIME[".json"], cache=False)
            if not RESET_SCRIPT.is_file():
                return self._send(
                    500,
                    json.dumps({"error": "reset script missing", "path": str(RESET_SCRIPT)}),
                    MIME[".json"],
                    cache=False,
                )
            try:
                # reset-tile.sh handles loadvm (fast) and restart (cold-boot, slow);
                # give it room. It prints one status line and exits 0 on success.
                proc = subprocess.run(
                    ["/bin/bash", str(RESET_SCRIPT), osid],
                    capture_output=True,
                    text=True,
                    timeout=180,
                )
                ok = proc.returncode == 0
                detail = (proc.stdout or proc.stderr or "").strip()
                sys.stderr.write(f"[serve] restore {osid}: rc={proc.returncode} {detail}\n")
                code = 200 if ok else 500
                return self._send(
                    code,
                    json.dumps(
                        {
                            "ok": ok,
                            "osId": osid,
                            "detail": detail,
                        }
                    ),
                    MIME[".json"],
                    cache=False,
                )
            except subprocess.TimeoutExpired:
                return self._send(
                    504, json.dumps({"ok": False, "osId": osid, "error": "reset timed out"}), MIME[".json"], cache=False
                )
            except Exception as e:
                return self._send(
                    500, json.dumps({"ok": False, "osId": osid, "error": str(e)}), MIME[".json"], cache=False
                )

        return self._send(404, json.dumps({"error": "not found"}), MIME[".json"], cache=False)

    def do_GET(self):
        path = unquote(urlparse(self.path).path)

        if self.public:
            if auth_routes.dispatch(self, path, "GET", AUTH, PUBLIC_ORIGIN):
                return
            if not self._public_gate(path):
                return
            if path in ("/login", "/admin", "/account", "/link") or path.startswith("/ui/"):
                return self._serve_auth_ui(path)

        if path == "/healthz":
            return self._send(200, "ok\n", "text/plain", cache=False)

        # GET /clientcmd?since=<seq> — authenticated operator-tab command polling. Queue file re-read
        # fresh per request; only cmds newer than the client's last-seen seq
        # are returned (replays are harmless: cmds are idempotent-tagged by seq).
        if path == "/clientcmd":
            if not self._require_admin("clientcmd poll"):
                return
            qs = parse_qs(urlparse(self.path).query)
            try:
                since = int(qs.get("since", ["0"])[0])
            except ValueError:
                since = 0
            doc = _clientcmd_load()
            cmds = [c for c in doc["cmds"] if int(c.get("seq", 0)) > since]
            if not OSG_ADMIN_EVAL:
                # A stale queue written during a prior opt-in must never execute
                # after the server returns to its default-safe configuration.
                cmds = [c for c in cmds if c.get("cmd") != "eval"]
            out = {"seq": doc["seq"], "cmds": cmds}
            return self._send(200, json.dumps(out), MIME[".json"], cache=False)

        if path == "/signal/index.json":
            tiles = load_tiles()
            out = {t: {"udpPort": v.get("udpPort")} for t, v in tiles.items()}
            return self._send(200, json.dumps(out), MIME[".json"], cache=False)

        if path.startswith("/signal/") and path.endswith(".json"):
            tile = path[len("/signal/") : -len(".json")]
            tiles = load_tiles()
            info = tiles.get(tile)
            if not info:
                return self._send(404, json.dumps({"error": "unknown tile", "tile": tile}), MIME[".json"], cache=False)
            hashfile = info.get("hashFile")
            try:
                cert_hash = Path(hashfile).read_text().strip()
            except Exception:
                return self._send(
                    503, json.dumps({"error": "cert hash not ready", "tile": tile}), MIME[".json"], cache=False
                )
            body = {
                "host": SIGNAL_HOST,
                "udpPort": info.get("udpPort"),
                "certHashB64": cert_hash,
            }
            # The daemon publishes its own identity beside the cert hash, and it
            # is that identity — SH_TILE — that it verifies a ticket against, so
            # that is what the ticket is signed over. The endpoint key normally
            # equals it (the registry refuses an id that differs from its
            # stationDir), but they are two different documents and the daemon is
            # the authority on its own: signing with the endpoint key while
            # `solaris` still ran as `solariscde` and `aros` as `amigaos` locked
            # both stations out of every session for four hours on 2026-08-05. Read
            # the authority from the daemon; fall back to the key for a station that
            # has not published one yet.
            ticket_tile = tile
            signal_doc = None
            try:
                signal_doc = json.loads(Path(hashfile).with_name("signaling.json").read_text())
                ticket_tile = signal_doc.get("tile") or tile
            except Exception:
                pass
            # The stream ticket is minted for EVERY caller, LAN included: a station
            # with SH_SESSION_KEY set refuses an unticketed session from any
            # source, so making this public-only would take the LAN gallery down.
            # Reaching this endpoint is itself the authorization — open on the
            # LAN, session-gated on the public listener.
            if STREAM_KEY:
                body["path"] = tickets.mint(STREAM_KEY, ticket_tile)
            if self.public:
                # Same station, same cert: WebTransport pins the certificate by
                # HASH, so the hostname it is reached under is not part of
                # verification. Only the route changes — the public relay host
                # instead of the LAN IP.
                body["host"] = PUBLIC_HOST
            # WebRTC is a platform capability for every station. The client enters
            # this path only when VideoDecoder is absent; WebCodecs-capable
            # clients ignore it and retain the WebTransport default.
            body["webrtc"] = {
                "offerUrl": f"/webrtc/{tile}/offer",
                "iceServers": _webrtc_ice_servers(),
                "jitterBufferTargetMs": 15,
            }
            # A restarted streamhost publishes its active QUIC policy beside
            # the cert hash (read above). Forward only that small optional
            # object so clients can report which MTU policy they actually
            # negotiated against; old/unrestarted stations simply omit it.
            if isinstance(signal_doc, dict) and isinstance(signal_doc.get("quic"), dict):
                body["quic"] = signal_doc["quic"]
            return self._send(200, json.dumps(body), MIME[".json"], cache=False)

        # ---- static UI ----
        return self._serve_static(path)

    @staticmethod
    def _parse_range(header, size):
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

    def _serve_auth_ui(self, path):
        """The sign-in and people-management pages.

        Deliberately NOT part of the SPA bundle: a signed-out visitor should not
        have to download a WebGL museum (or learn every asset name in it) to be
        shown a login button.
        """
        name = _AUTH_PAGES.get(path) or path[len("/ui/") :]
        target = (AUTH_UI / name).resolve()
        if target != AUTH_UI and AUTH_UI not in target.parents:
            return self._send(403, "forbidden\n", "text/plain")
        if not target.is_file():
            return self._send(404, "not found\n", "text/plain")
        ctype = MIME.get(target.suffix, "application/octet-stream")
        return self._send(200, target.read_bytes(), ctype, cache=False)

    def _serve_static(self, path):
        rel = path.lstrip("/")
        target = (WEBROOT / rel).resolve()
        # containment guard — a true ancestor check (NOT a string prefix, which
        # would wrongly admit a sibling like `<webroot>-secrets/…`). WEBROOT is
        # already .resolve()'d at startup, so symlink/`..` escapes fail this too.
        if target != WEBROOT and WEBROOT not in target.parents:
            return self._send(403, "forbidden\n", "text/plain")

        if path == "/" or target.is_dir():
            target = WEBROOT / "index.html"

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
            if not path.startswith(reserved) and not Path(path).suffix:
                target = WEBROOT / "index.html"
            else:
                return self._send(404, "not found\n", "text/plain")

        ctype = MIME.get(target.suffix.lower(), "application/octet-stream")
        # index.html must never be cached (so redeploys show up); assets are
        # content-hashed by vite so they can cache hard.
        cache = target.name != "index.html"

        try:
            size = target.stat().st_size
        except Exception:
            return self._send(404, "not found\n", "text/plain")

        # HTTP Range (single "bytes=start-end") — lets <video> scrub/seek without
        # pulling the whole clip. Absent/malformed/multi-range headers fall
        # through to the plain 200 full-body path.
        rng = self._parse_range(self.headers.get("Range"), size)
        if rng is None:
            try:
                data = target.read_bytes()
            except Exception:
                return self._send(404, "not found\n", "text/plain")
            return self._send(200, data, ctype, cache=cache)

        start, end = rng  # inclusive offsets
        if start > end or start >= size:
            # Unsatisfiable (RFC 7233 §4.4): 416 + Content-Range: bytes */size.
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.send_header("Content-Length", "0")
            self.send_header("Accept-Ranges", "bytes")
            self._cors()
            self.end_headers()
            return

        try:
            with target.open("rb") as f:
                f.seek(start)
                data = f.read(end - start + 1)
        except Exception:
            return self._send(404, "not found\n", "text/plain")

        # 206 partial — mirror _send's header/HEAD-guard idiom, plus range headers.
        self.send_response(206)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Accept-Ranges", "bytes")
        self._cors()
        if not cache:
            self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

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

    AUTH = AuthService(AUTH_STATE, rp_id=PUBLIC_HOST, rp_name="OS gallery", origin=PUBLIC_ORIGIN)
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

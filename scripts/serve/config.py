"""Env-derived configuration shared by osgallery-https-server.py and the route
modules it delegates to. Everything here is read ONCE at import time and never
reassigned afterward — the two exceptions (AUTH, STREAM_KEY, filled in by
main()/_start_public_listener() when the public listener is enabled) stay
module globals on osgallery-https-server.py itself, not here, because a
`from config import X` binding would freeze at the pre-startup value."""

from __future__ import annotations

import os
from pathlib import Path

_HERE = Path(__file__).resolve().parent

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
AUTH_STATE = Path(os.environ.get("AUTH_STATE", str(_HERE / "auth-state.json")))
AUTH_UI = Path(os.environ.get("AUTH_UI", str(_HERE / "authui")))
# Interaction counters (serve/usage.py). Its OWN file: auth-state.json is the
# irreplaceable account database and a counter written every few seconds has no
# business sharing it.
USAGE_STATS = Path(os.environ.get("USAGE_STATS", str(_HERE / "usage-stats.json")))
# Feature-reach / flow / error counters (serve/analytics.py). A THIRD file for a
# third question: clientlog.jsonl is a rolling window pruned by age, usage-stats
# is per-STATION popularity, and this is per-FEATURE reach that has to outlive
# both. SQLite rather than JSON because it is read by day-range and appended to
# by every tab; a whole-document rewrite per batch is what the other two can
# afford and this cannot.
ANALYTICS_DB = Path(os.environ.get("ANALYTICS_DB", str(_HERE / "analytics.db")))
# Correlated per-session TRACES (serve/traces.py). Its own database, not a
# table beside the counters, because everything about it differs: rows are
# kilobytes not integers, retention is days not years, and reads are admin-only
# where the aggregates are open. One store would have to take the strictest of
# each and the counters would lose their openness to a rule that is not theirs.
TRACES_DB = Path(os.environ.get("TRACES_DB", str(_HERE / "traces.db")))
# Days of spans kept. Short on purpose — see docs/ANALYTICS.md on what the trace
# lane costs in exchange for drilldown.
TRACE_RETENTION_DAYS = int(os.environ.get("TRACE_RETENTION_DAYS", "14"))
# The correlated LOG lane, beside traces.db rather than a table in it: a log
# row is roughly an order of magnitude more voluminous than a trace row at this
# box's traffic (~20 MB/day against ~2 MB/day), and giving it its own file
# means its retention, its WAL and its runaway backstop can be tuned without
# touching the store the Applications view reads.
LOGS_DB = Path(os.environ.get("LOGS_DB", str(_HERE / "logs.db")))
# SEVEN days, half the trace window. Two reasons, both defensible on one box:
# a log row costs ~10x a trace row, and 7 days is Instana's own default log
# retention ("All the collected logs are kept for 7 days", 0321-policies.md),
# so both stores answer a question for the same window.
LOG_RETENTION_DAYS = int(os.environ.get("LOG_RETENTION_DAYS", "7"))
# Days of per-day detail kept (serve/analytics.py prunes on startup).
ANALYTICS_RETENTION_DAYS = int(os.environ.get("ANALYTICS_RETENTION_DAYS", "730"))

# Shared with every streamhost unit as SH_SESSION_KEY. Read once at startup:
# rotating it means restarting both sides anyway.
STREAM_KEY_FILE = Path(os.environ.get("STREAM_KEY_FILE", str(_HERE / "pki" / "stream-ticket.key")))
# Standalone pages the auth plane serves, outside the UI bundle.
AUTH_PAGES = {
    "/login": "login.html",
    "/admin": "admin.html",
    "/account": "account.html",
    "/link": "link.html",
}

# --- the walk-in plane (docs/lab/walkin/CONTRACT-LEDGER.md) ------------------
# Adding an OS to the pool is DATA: the broker reads registry/walkin/*.json out
# of the box's repo checkout, and the launcher paths inside those files are
# relative to its root. Point WALKIN_REGISTRY at a directory that does not
# exist and the pool is simply absent — the server, the LAN gallery and the
# invited plane all behave exactly as they did before the plane was built. The
# switch itself is auth's (walkin.access, default closed) and the env FLOOR is
# WALKIN_OPEN; neither is read here.
WALKIN_REGISTRY = Path(os.environ.get("WALKIN_REGISTRY", "/data/kernel-hive/registry/walkin"))
WALKIN_REPO = Path(os.environ.get("WALKIN_REPO", "/data/kernel-hive"))
# The watchdog interval. Nothing else calls Broker.tick(), and it is what
# expires a session on its TTL, reaps an idle one and keeps the pool warm — so
# this is not a tuning knob, it is the resolution of every deadline the ledger
# promises a visitor.
WALKIN_TICK_SECS = int(os.environ.get("WALKIN_TICK_SECS", "15") or 15)

# --- POST /restore/<osId> : reset-to-golden button endpoint ------------------
# The single authority (reset-tile.sh + golden-manifest.json) shared with the
# Playwright input suite's reset-before-run. Defaults sit beside this server so a
# production deploy needs no test dir. Token-gated + non-destructive by construction.
RESET_SCRIPT = Path(os.environ.get("RESET_SCRIPT", str(_HERE / "reset-tile.sh")))
GOLDEN_MANIFEST = Path(os.environ.get("GOLDEN_MANIFEST", str(_HERE / "golden-manifest.json")))
# Restore is enabled by default; set RESTORE_ENABLE=0 to disable the endpoint.
RESTORE_ENABLE = os.environ.get("RESTORE_ENABLE", "1") not in ("0", "false", "no")

# --- client observability: /clientlog + /clientcmd ---------------------------
# Telemetry sink + command queue for the UI (Firefox decoder debugging et al).
# All files sit beside this server by default so a production deploy needs no
# extra config; every one is (re-)read or appended per request — no restart
# needed after hand-edits, and restart-https.sh's log truncation never touches
# clientlog.jsonl.
CLIENTLOG = Path(os.environ.get("CLIENTLOG", str(_HERE / "clientlog.jsonl")))
CLIENTLOG_MAX = int(os.environ.get("CLIENTLOG_MAX", str(64 * 1024 * 1024)))
# Rolling RETENTION WINDOW (seconds) for the client telemetry log. The size cap
# above is only a runaway backstop now: what the operator actually wants is "the
# last day of streaming diagnostics", and since the client samples its full
# overlay state every 5 s (see streamClient/telemetry.ts formatStatsLine) a
# blind size rotation could drop this morning's evidence by lunchtime under
# heavy use. Rotation therefore PRUNES BY AGE and keeps one generation.
CLIENTLOG_RETENTION_SECS = int(os.environ.get("CLIENTLOG_RETENTION_SECS", str(36 * 3600)))
CLIENTLOG_BODY_MAX = 16 * 1024  # request-body cap (shared by /clientcmd/admin)
WEBRTC_OFFER_BODY_MAX = 128 * 1024
WEBRTC_BRIDGE_UPSTREAM = os.environ.get("WEBRTC_BRIDGE_UPSTREAM", "http://127.0.0.1:18080").rstrip("/")
WEBRTC_ICE_SERVERS_FILE = Path(os.environ.get("WEBRTC_ICE_SERVERS_FILE", str(_HERE / "webrtc-ice-servers.json")))
# The Instana EUM beacon proxy's ONE upstream (scripts/serve/eum_proxy.py): a
# single-line file holding the tenant's reporting URL. A FILE rather than an
# environment variable because the systemd unit is committed to a public repo
# with placeholder addresses in it and the tenant URL is not publishable — the
# same reason WEBRTC_ICE_SERVERS_FILE is a file with a committed `.example`
# beside it. scripts/serve-https-spa.sh publishes it from registry/local.env at
# deploy time, alongside the vendor agent itself. Absent means the proxy is not
# configured and POST /eum 404s, which is what a fresh clone must look like.
INSTANA_EUM_UPSTREAM_FILE = Path(os.environ.get("INSTANA_EUM_UPSTREAM_FILE", str(_HERE / "instana-eum-upstream.txt")))
CLIENTCMD = Path(os.environ.get("CLIENTCMD", str(_HERE / "clientcmd.json")))
CLIENTCMD_TOKEN = Path(os.environ.get("CLIENTCMD_TOKEN", str(_HERE / "pki" / "clientcmd.token")))
# Append-only record of every command an operator ISSUED. Deliberately NOT
# clientlog.jsonl: that file is a rolling window that prunes itself by age, and
# an audit trail that deletes itself is not an audit trail.
CLIENTCMD_AUDIT = Path(os.environ.get("CLIENTCMD_AUDIT", str(_HERE / "clientcmd-audit.jsonl")))
CLIENTCMD_ALLOWED = ("snapshot", "verbose", "reload", "eval")
CLIENTCMD_KEEP = 100  # queue trimmed to the last N commands

# --- ADMIN SECURITY BOUNDARY -------------------------------------------------
# The edge tunnel terminates on the PUBLIC listener, which is bound to loopback,
# so on that listener every peer looks like 127.0.0.1 and client_address is
# telemetry only, NEVER authorization. The command ENQUEUE is refused on that
# listener outright (auth/gate.py BLOCKED_PREFIXES) and on the LAN listener —
# where the peer is real — requires a loopback peer AND the file-backed
# X-Admin-Token. Issuing a command is a box-side act; no UI session has a path
# to it.
#
# Because of that, arbitrary-JS eval no longer carries a second opt-in. The old
# default-off OSG_ADMIN_EVAL=1 ritual guarded a browser-reachable enqueue; with
# no such path it protects nothing and only defeats the purpose — it does not
# survive a reboot, so it turned every debugging session into a box-side chore
# at exactly the moment a live session needed inspecting. The variable survives
# as an explicit DISABLE switch: set OSG_ADMIN_EVAL=0 to shut eval off.
OSG_ADMIN_EVAL = os.environ.get("OSG_ADMIN_EVAL", "1").strip().lower() not in (
    "0",
    "false",
    "no",
    "off",
)

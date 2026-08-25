"""What a public visitor may reach before they have signed in.

The LAN listener is untouched by any of this: it keeps the open, tokenless
behaviour every lab script and the live Playwright suite depend on. Only the
loopback listener that the edge tunnel is wired to runs through this gate.

The default is deny. A path is reachable without a session only by being named
here, so adding a route to the server cannot silently publish it.
"""

from __future__ import annotations

# Reachable with no session: the login page and the auth API itself, plus the
# health probe the deploy scripts poll. Everything else needs a session.
# /link is open because a device arrives there with nothing but a code — it
# is the sign-in path for a device that has no passkey yet.
# /manifest.webmanifest and /sw.js are open because a browser judges the app
# INSTALLABLE by fetching the manifest and its icons WITHOUT credentials (a
# <link rel="manifest"> and the icon reads carry no session cookie); behind the
# gated tunnel they would 401 and Chrome would never offer "Install". None of it
# is private — the app's name, its caching worker, and the museum's mark.
# The two walk-in routes ledger §3 marks `public` are open here because they
# have to be: a stranger with no account polls `/walkin/state` to learn whether
# the plane is open at all, and `/walkin/signup` is how they get an account in
# the first place. Neither leaks anything — the state doc is a switch position
# and a free/size count, and signup is refused unless the switch is at Open.
# The rest of `/walkin/*` (claim, release, reset, manifest) needs a session and
# is deliberately NOT here (PREFLIGHT.md B4).
#
# NOT open, and it is a deliberate open decision rather than an oversight:
# `/walkin` itself, the landing PAGE. A signed-out browser asking for it is
# redirected to /login like any other page, so the sign-up flow is unreachable
# to a stranger until somebody adds "/walkin" to this set. That is the same
# decision as whether the gallery links it at all, and it is the operator's;
# at Invited — where the wave ships — it changes nothing, because signup is
# 403 there anyway.
OPEN_PATHS = frozenset(
    {
        "/healthz",
        "/login",
        "/link",
        "/favicon.ico",
        "/manifest.webmanifest",
        "/sw.js",
        # The landing page itself. A stranger arrives signed out BY DEFINITION,
        # so gating it redirects the entire walk-in audience to /login and no
        # one ever reaches signup. The page shows the closed notice when the
        # switch is not Open, so this is safe at every switch position.
        "/walkin",
        "/walkin/state",
        "/walkin/signup",
        "/walkin/signup/begin",
        "/walkin/signup/finish",
    }
)
# /ui/ is the sign-in and people-management page bundle. It is open in full,
# including admin.js: that file describes an API surface which is documented in
# the repo anyway, and every call it makes is authorized server-side. Keeping
# the rule "the login UI is open" simple beats a per-asset list that will drift.
# /assets/ is the SPA bundle, and it is open because the walk-in landing page IS
# the SPA: a stranger arrives signed out, so refusing the bundle serves them the
# HTML shell with a 401 script and stylesheet — a white page, which is exactly
# what shipped on 2026-08-25. What this publishes is application code, already
# served to every signed-in visitor and readable in a public repo; it publishes
# no data, because every route the bundle CALLS is still gated (the full-fleet
# manifest, the fleet table, station signaling, /admin, /clientcmd*).
OPEN_PREFIXES = ("/auth/", "/ui/", "/assets/")

# Refused outright on this listener: the command ENQUEUE. Nothing a browser can
# reach may issue a command to the server side. `clientcmd.sh` posts to
# https://127.0.0.1:8443 on the box and is unaffected; a UI session — on a
# phone, on the LAN, or through the edge tunnel — gets a flat 404.
#
# This deliberately gives up issuing commands FROM a phone, which this comment
# used to defend. It does NOT give up debugging a phone, and that distinction is
# the whole point: a phone session is the TARGET. It polls, receives the
# operator's command and reports back, so touch and stylus bugs are as reachable
# as they ever were — more so, because every authenticated session now polls
# rather than only an admin's own tab. The only thing removed is the phone as a
# SOURCE of commands, which is exactly what was asked for.
BLOCKED_PREFIXES: tuple[str, ...] = ("/clientcmd/admin",)

# The command plane is split BY DIRECTION, and the halves are not merely gated
# differently — they are reachable from different places.
#
# The POLL (GET /clientcmd) is the read half: a tab asking "is there a command
# for me?". ANY authenticated gallery session may poll, because remote debugging
# has to work for every visitor, always — the session that fails is exactly the
# one worth reaching, and it is never an operator's own tab. Polling confers no
# authority: it READS the operator's queue, and a tab acts on a command only
# when that command is addressed to it. So the poll is deliberately NOT listed
# here — the gate's default for a signed-in user is "allow", which is what we
# want.
#
# The ENQUEUE (POST /clientcmd/admin) is the write half, and it is in
# BLOCKED_PREFIXES above: unreachable from any browser at all. Issuing a command
# is a box-side act, authenticated by the operator token over loopback.
#
# Nothing else is admin-only on this listener, so these are now empty.
ADMIN_PATHS: frozenset[str] = frozenset()
ADMIN_PREFIXES: tuple[str, ...] = ()


def is_blocked(path: str) -> bool:
    return path.startswith(BLOCKED_PREFIXES)


def is_open(path: str) -> bool:
    return path in OPEN_PATHS or path.startswith(OPEN_PREFIXES)


def wants_html(accept_header: str | None) -> bool:
    """Whether to answer a signed-out request with the login PAGE rather than a
    401. A browser navigating to the gallery should land on the login screen;
    the SPA's own fetches should get a status code they can act on."""
    return "text/html" in (accept_header or "")


# ---- the walk-in role ------------------------------------------------------
#
# A walk-in is an anonymous stranger with an account (WALKIN-BRIEF.md §5), so
# their fence is an ALLOWLIST and its default is deny — the opposite way round
# from the signed-in gate above, where "authenticated is enough". A route added
# to the server is invisible to walk-ins until it is named here.

# Exact paths a walk-in may reach beyond the open set. `/account` is theirs:
# managing their own passkeys is not an operator power.
WALKIN_PATHS = frozenset(
    {
        "/",
        "/index.html",
        "/account",
        "/walkin",
        "/walkin/state",
        "/walkin/signup",
        "/walkin/claim",
        "/walkin/release",
        "/walkin/reset",
        "/walkin/manifest.json",
        "/walkin/exhibits",
        # The curatorial prose. A static document with no live field in it.
        "/poster-docs.json",
        # Telemetry in, aggregate counter out. Debugging a broken stream has to
        # work for the visitor whose stream is broken (STREAM-DEBUGGING.md), and
        # a walk-in is exactly the session nobody can reach any other way.
        "/clientlog",
        "/usage",
    }
)
# Prefixes: the SPA bundle, the museum's own art, and the poster heroes —
# captured stills already published to the webroot.
WALKIN_PREFIXES = ("/assets/", "/posters/", "/walkin/play/", "/fonts/")

# The exhibition fields, named to KEEP (brief §5.3). Built as an allowlist so a
# field added to the registry later is invisible to walk-ins until somebody
# deliberately exposes it. `id` is here as the join key the SPA needs to reach
# the poster and hero for a row; it is already public in the poster index.
WALKIN_MANIFEST_FIELDS = (
    "id",
    "displayName",
    "year",
    "era",
    "eraLabel",
    "lineage",
    "arch",
    "notes",
    "blurb",
    "eraSoftware",
    "iconicApps",
    "periodBrowser",
    "accent",
)


def walkin_allows(path: str, own_signal: str | None = None) -> bool:
    """Whether a `walkin` session may reach `path`.

    `own_signal` is the signaling path of the visitor's OWN clone, minted by
    their claim. It is the only interactive surface a walk-in ever gets: every
    other station's signaling — and the fleet index that would enumerate them —
    is refused here rather than filtered downstream.
    """
    if is_blocked(path):
        return False
    if own_signal and path == own_signal:
        return True
    if own_signal and path.startswith(_webrtc_prefix(own_signal)):
        return True
    if path.startswith("/signal/") or path.startswith("/webrtc/"):
        return False
    if is_open(path):
        return True
    return path in WALKIN_PATHS or path.startswith(WALKIN_PREFIXES)


def _webrtc_prefix(own_signal: str) -> str:
    """`/signal/walkin-os2warp-3.json` -> `/webrtc/walkin-os2warp-3/`."""
    clone = own_signal[len("/signal/") : -len(".json")]
    return f"/webrtc/{clone}/"


def allows(path: str, user: dict | None, own_signal: str | None = None) -> bool:
    """The role fence. Non-walk-in sessions keep the behaviour they had:
    signed in is enough for everything this listener still serves."""
    if user and user.get("role") == "walkin":
        return walkin_allows(path, own_signal)
    return not is_blocked(path)


def landing_for(user: dict | None) -> str:
    """Where to send a browser that was refused an HTML page. A walk-in belongs
    on the walk-in landing page, not on the invited plane's login screen."""
    return "/walkin" if user and user.get("role") == "walkin" else "/login"


def walkin_manifest(entries: list[dict], own: dict | None = None) -> dict:
    """Project the gallery manifest down to what a walk-in may see.

    Two rules, both from brief §5.3. The fields are named to KEEP, never
    deleted to hide. And `signalEndpoint`/`transport` — the interactive
    surface — survive for exactly one row: the station the visitor holds a
    clone of, carrying the CLONE's endpoint, not the museum station's.

    `own` is `{"station": …, "clone": …, "signalEndpoint": …, "transport": …}`
    or None for a visitor who has not claimed anything yet.
    """
    playable = (own or {}).get("station")
    rows = []
    for entry in entries:
        # Dark-launched exhibits are not public yet, walk-ins included.
        if entry.get("listed") is False:
            continue
        row = {key: entry[key] for key in WALKIN_MANIFEST_FIELDS if key in entry}
        if playable and entry.get("id") == playable:
            row["signalEndpoint"] = own["signalEndpoint"]
            row["transport"] = own.get("transport", "streamhost")
            row["clone"] = own.get("clone", "")
            row["playable"] = True
        rows.append(row)
    return {"_projection": "walk-in allowlist; exhibition fields only", "entries": rows}

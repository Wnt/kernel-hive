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
OPEN_PATHS = frozenset({"/healthz", "/login", "/link", "/favicon.ico", "/manifest.webmanifest", "/sw.js"})
# /ui/ is the sign-in and people-management page bundle. It is open in full,
# including admin.js: that file describes an API surface which is documented in
# the repo anyway, and every call it makes is authorized server-side. Keeping
# the rule "the login UI is open" simple beats a per-asset list that will drift.
# /assets/generated/ holds only the generated art + application icons (never the
# SPA bundle, which stays under /assets/), so opening it publishes the PWA icons
# for the installability check without exposing any application code.
OPEN_PREFIXES = ("/auth/", "/ui/", "/assets/generated/")

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

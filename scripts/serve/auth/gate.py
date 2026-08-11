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
OPEN_PATHS = frozenset({"/healthz", "/login", "/link", "/favicon.ico"})
# /ui/ is the sign-in and people-management page bundle. It is open in full,
# including admin.js: that file describes an API surface which is documented in
# the repo anyway, and every call it makes is authorized server-side. Keeping
# the rule "the login UI is open" simple beats a per-asset list that will drift.
OPEN_PREFIXES = ("/auth/", "/ui/")

# Nothing is refused outright any more. The operator plane used to be shut on
# this listener, which also made it unusable from a PHONE — the one place the
# touch and stylus bugs actually live, and the one place with no console to
# paste an operator token into. It is reachable now, admin-only.
BLOCKED_PREFIXES: tuple[str, ...] = ()

# Reachable only with an ADMIN session (or the operator token). Both directions
# of the command plane: the poll a tab makes, and the enqueue that puts a
# command in front of it. Arbitrary-JS `eval` needs OSG_ADMIN_EVAL=1 on top of
# this, which is default-off and does not survive a reboot — so the dangerous
# verb still takes a deliberate act on labhost, not just an admin cookie.
ADMIN_PATHS = frozenset({"/clientcmd", "/clientcmd/admin"})
ADMIN_PREFIXES = ("/clientcmd",)


def is_blocked(path: str) -> bool:
    return path.startswith(BLOCKED_PREFIXES)


def is_open(path: str) -> bool:
    return path in OPEN_PATHS or path.startswith(OPEN_PREFIXES)


def wants_html(accept_header: str | None) -> bool:
    """Whether to answer a signed-out request with the login PAGE rather than a
    401. A browser navigating to the gallery should land on the login screen;
    the SPA's own fetches should get a status code they can act on."""
    return "text/html" in (accept_header or "")

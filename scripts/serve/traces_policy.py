"""What may enter the trace store — the content policy, in one place.

SPLIT OUT OF `traces.py` on 2026-09-01, when the richness pass and a credential
guard together pushed that file past its size budget. This is a cohesive unit
in its own right: `traces.py` answers HOW a span is stored, this answers WHAT
is allowed to be in one. Everything moved verbatim.

READ docs/ANALYTICS.md §0 BEFORE ADDING A RESTRICTION HERE. Most of what used
to live in this block was invented by earlier sessions and removed on that
date. Two rules are real and stay: a credential must never be stored, and the
operator has not authorised typed keystroke content.
"""

from __future__ import annotations

import os
import re

#: Attributes refused outright, regardless of who sends them, because they carry
#: CREDENTIALS. This is the security rule, and it is the only content rule this
#: file has: a stored credential is one an admin view, a backup or a forwarded
#: OTLP batch can replay. Everything else — stacks, URLs, query strings, the
#: account that hit the fault — is wanted (see the module docstring).
BANNED_ATTRS = frozenset(
    {
        "kh.ticket",
        "kh.ticket.path",
        "http.request.header.authorization",
        "http.request.header.cookie",
        "http.response.header.set-cookie",
    }
)
#: The same rule as a shape, because a name nobody thought of is the one that
#: leaks. Checked against every attribute key in the live store before landing:
#: it matches none of them (`kh.ticket.kind`, `kh.auth.role`, `kh.auth.decision`
#: and the 75 others all survive).
SECRET_KEY_RE = re.compile(
    r"(authorization|cookie|passwd|password|secret|api[-_.]?key|credential|passkey|"
    r"private[-_.]?key|bearer|token)",
    re.I,
)
#: TYPED KEYSTROKE CONTENT — the one item on the 2026-09-01 richness pass that
#: was NOT authorised, and must not be enabled without the operator saying so.
#: The gallery has walk-in visitors who are real third parties; what a stranger
#: types is materially different from every other field here, and the operator
#: has not been asked. The plumbing exists so the answer is one env var rather
#: than a fresh design: set `KH_TRACE_TYPED_TEXT=1` in the serving unit to let
#: these through. Timing, scancode CLASS and record type are unaffected and were
#: never gated by this — only the characters themselves.
TYPED_TEXT_ATTRS = frozenset(
    {
        "kh.input.text",
        "kh.input.chars",
        "kh.key.name",
        "kh.key.char",
    }
)
TYPED_TEXT_ALLOWED = os.environ.get("KH_TRACE_TYPED_TEXT") == "1"


def refused(key: str) -> bool:
    """Is this attribute name refused at intake? Credentials always; typed
    keystroke content unless the operator has armed `KH_TRACE_TYPED_TEXT`."""
    if key in BANNED_ATTRS or SECRET_KEY_RE.search(key):
        return True
    return key in TYPED_TEXT_ATTRS and not TYPED_TEXT_ALLOWED


#: Query parameters whose VALUE is a credential, redacted out of URL-shaped
#: attributes. The key-name guard above cannot see these: the attribute is
#: honestly called `url.query`, and the secret is inside its value. The stream
#: ticket is the live example — `signal_route.py` mints it INTO a query string
#: because the raw WebTransport plane has no headers to carry it, so a stored
#: `url.full` for a stream connect would be a stored credential. Redacting the
#: value keeps the rest of the URL, which is the part with diagnostic worth.
SECRET_PARAM_RE = re.compile(
    r"(?i)\b(ticket|token|secret|key|sig|signature|auth|password|passwd|code)"
    r"(=)([^&\s]*)"
)
#: Attributes whose value is a URL and may therefore carry the above.
URL_VALUE_ATTRS = frozenset({"url.full", "url.query", "http.url", "http.target"})


def redact_url_value(value: str) -> str:
    """Blank the value of any credential-shaped query parameter, keep the rest."""
    return SECRET_PARAM_RE.sub(lambda m: m.group(1) + m.group(2) + "REDACTED", value)

"""What an unauthenticated browser must be able to fetch (scripts/serve/auth/gate.py).

Regression coverage for the outage where /vendor/ was missing from
OPEN_PREFIXES: the self-hosted Instana EUM agent 401'd for every signed-out
visitor, so no page-load beacon was ever produced. spa/index.html loads the
agent script BEFORE any auth decision (see its own comment), so anything it —
or the built bundle — references has to be open here or the reference just
silently 401s.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "serve"))
sys.path.insert(0, str(ROOT / "scripts" / "serve" / "auth"))

import gate  # noqa: E402

INDEX_HTML = (ROOT / "spa" / "index.html").read_text(encoding="utf-8")


class TestVendorIsOpen(unittest.TestCase):
    """The regression this fix exists for."""

    def test_the_instana_agent_is_open_to_a_signed_out_request(self):
        self.assertTrue(gate.is_open("/vendor/instana-eum.min.js"))

    def test_the_vendor_prefix_is_open_in_general(self):
        self.assertTrue(gate.is_open("/vendor/anything-else.js"))

    def test_a_walk_in_reaches_the_agent_too(self):
        # walkin_allows() checks is_open() first, so /vendor/ does not need
        # (and deliberately does not have) its own WALKIN_PREFIXES entry.
        self.assertTrue(gate.walkin_allows("/vendor/instana-eum.min.js"))


class TestTheGateStillBites(unittest.TestCase):
    """Prove the fix did not widen the fence beyond /vendor/."""

    def test_a_genuinely_gated_surface_is_still_gated(self):
        for path in ("/fleet", "/fleet-table.json", "/admin", "/clientcmd", "/gallery-manifest.json"):
            self.assertFalse(gate.is_open(path), path)

    def test_the_command_enqueue_is_still_blocked_outright(self):
        self.assertTrue(gate.is_blocked("/clientcmd/admin"))


class TestEveryPathIndexHtmlReferencesIsOpen(unittest.TestCase):
    """The general rule, not just this one instance: `spa/index.html` names a
    fixed set of paths an unauthenticated browser must fetch before the app
    (or even React) has evaluated — icons, the manifest, and the vendor
    agent. Every one of them has to answer to a signed-out request or it
    breaks silently, exactly like /vendor/ did. Extracted straight from the
    file with a small, permissive regex rather than a hand-maintained list,
    so a new reference added to the head is caught here automatically."""

    # href="/..." / src="/..." (an HTML attribute) OR `agent.src = '/...'`
    # (the Instana bootstrap sets `.src` as a JS property, not a markup
    # attribute, hence the optional whitespace around `=`) — root-relative
    # only. The module entry (`/src/main.tsx`) is a dev-server-only path
    # replaced by Vite's own build with a hashed /assets/ file, so it is
    # excluded on purpose.
    _REF_RE = re.compile(r"""(?:href|src)\s*=\s*["'](/[^"'%]*)["']""")

    def _referenced_paths(self) -> list[str]:
        paths = [m for m in self._REF_RE.findall(INDEX_HTML) if m != "/src/main.tsx"]
        self.assertTrue(paths, "regex found nothing in spa/index.html — check it still matches the markup")
        return paths

    def test_every_referenced_path_is_open(self):
        for path in self._referenced_paths():
            self.assertTrue(gate.is_open(path), f"{path} is referenced by index.html but gated")


if __name__ == "__main__":
    unittest.main()


class TestTheEndedSessionSeam(unittest.TestCase):
    """The 410 seam: a stranger whose intro time ran out may READ the verdict.

    The reap that ends a walk-in session also clears `own_of`, so the fence had
    nothing to match their own `/signal/<clone>.json` against and refused it
    401 — ahead of the `signal_route.py` branch that answers 410 `session-end`
    / `WALKIN_ANON_BUDGET`. That made the conversion moment unreachable for the
    only role it was written for: a signed-in visitor never saw it, because
    `allows()` lets every other role through unconditionally. Measured on the
    public gallery 2026-09-11 04:14:39Z (walkin-rhapsody-2, three 401s after a
    WALKIN_TTL reap, rendered to the visitor as "Reconnecting (1/6…4/6)").

    The seam is one document wide. Everything below the first test is a
    negative, because widening this fence is how a stranger reaches a machine.
    """

    OWN = "/signal/walkin-os2warp-4.json"
    OTHER = "/signal/walkin-win311-9.json"

    def roles(self):
        return ({"role": "anon", "id": "anon:v1"}, {"role": "walkin", "id": "u1"})

    def test_the_visitor_may_read_the_clone_they_just_lost(self):
        for user in self.roles():
            self.assertTrue(gate.allows(self.OWN, user, None, self.OWN), user["role"])

    def test_a_live_holding_is_unchanged(self):
        for user in self.roles():
            self.assertTrue(gate.allows(self.OWN, user, self.OWN, None), user["role"])
            self.assertTrue(gate.allows("/webrtc/walkin-os2warp-4/offer", user, self.OWN, None))

    def test_an_ended_session_may_not_reach_anyone_else_s_clone(self):
        for user in self.roles():
            self.assertFalse(gate.allows(self.OTHER, user, None, self.OWN), user["role"])

    def test_an_ended_session_may_not_negotiate_media(self):
        """Explaining itself is a read; the webrtc offer under it is not.

        Matched EXACTLY in the fence rather than as a prefix, which is the whole
        difference between "your time is up" and a second turn on the machine.
        """
        for user in self.roles():
            for path in (
                "/webrtc/walkin-os2warp-4/offer",
                "/webrtc/walkin-os2warp-4/",
                "/webrtc/walkin-os2warp-4/candidate",
            ):
                self.assertFalse(gate.allows(path, user, None, self.OWN), f"{user['role']} {path}")

    def test_an_ended_session_may_not_enumerate_the_fleet(self):
        for user in self.roles():
            self.assertFalse(gate.allows("/signal/index.json", user, None, self.OWN))
            self.assertFalse(gate.allows("/signal/win95.json", user, None, self.OWN))

    def test_with_no_ended_session_a_stranger_reaches_no_signal_at_all(self):
        for user in self.roles():
            self.assertFalse(gate.allows(self.OWN, user, None, None), user["role"])

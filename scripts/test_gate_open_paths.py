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

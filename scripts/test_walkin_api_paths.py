"""Three files have to agree about what `/walkin/...` is, and one day two did.

    python3 -m unittest test_walkin_api_paths

`/walkin/engage` shipped on 2026-09-11 with a handler in
`serve/walkin/routes.py`, an entry in `serve/auth/gate.py`'s anonymous
allowlist, and no line in `serve/walkin_plane.py`'s `API` tuple — which is what
actually decides whether a path under `/walkin/` belongs to the broker at all.
So every call fell through to the SPA catch-all and 404ed on the live box, for
every visitor, while the feature's own unit tests passed: they entered at
`routes.dispatch`, one layer BELOW the list that was wrong.

The list is now written once (`walkin.routes.PATHS`) and read by everything
else, which removes the drift rather than detecting it. What is left to check is
the seam a single list cannot close — that the dispatcher's own `if path == …`
chain and that list say the same thing — plus the two agreements that span
modules. All three are read OUT OF THE SOURCE with `ast`: hard-coding the
expected paths here would just be a fourth list to forget.

Nothing is imported. `walkin_plane` pulls in the auth plane, which needs
`fido2`, which CI does not have — and a check that cannot run in CI is exactly
the shape of the hole this file exists to fill.
"""

from __future__ import annotations

import ast
import unittest
from pathlib import Path

SERVE = Path(__file__).resolve().parent / "serve"
ROUTES = SERVE / "walkin" / "routes.py"
PLANE = SERVE / "walkin_plane.py"
GATE = SERVE / "auth" / "gate.py"

PREFIX = "/walkin/"


def _tree(path: Path) -> ast.Module:
    return ast.parse(path.read_text(), filename=str(path))


def _strings(node: ast.AST) -> set[str]:
    """Every string constant anywhere under `node`."""
    return {n.value for n in ast.walk(node) if isinstance(n, ast.Constant) and isinstance(n.value, str)}


def _assigned(tree: ast.Module, name: str) -> ast.AST | None:
    """The value assigned to a module-level `name`, or None."""
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return node.value
    return None


def _branched_on(tree: ast.Module, variable: str) -> set[str]:
    """Every `/walkin/...` literal the source COMPARES `variable` against.

    This is the dispatcher's real behaviour — the `if path == "/walkin/claim"`
    chain — read without running it. Both `==` and `in (...)` are collected,
    because either is a way to route a path.
    """
    found: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Compare):
            continue
        if not (isinstance(node.left, ast.Name) and node.left.id == variable):
            continue
        for other in node.comparators:
            found |= {s for s in _strings(other) if s.startswith(PREFIX)}
    return found


class RoutesAreTheOneList(unittest.TestCase):
    """`walkin.routes.PATHS` and the chain beneath it name the same paths."""

    def setUp(self):
        self.tree = _tree(ROUTES)
        self.paths = _strings(_assigned(self.tree, "GET_PATHS")) | _strings(_assigned(self.tree, "POST_PATHS"))

    def test_the_list_is_not_empty(self):
        self.assertIn("/walkin/state", self.paths)
        self.assertIn("/walkin/claim", self.paths)
        self.assertIn("/walkin/engage", self.paths, "the route this file was written for")

    def test_every_routed_path_is_declared(self):
        # Add an `elif path == "/walkin/whatever"` without listing it and the
        # guard at the top of dispatch() refuses it before the branch is ever
        # reached — a handler that silently does nothing. This is that trap.
        undeclared = _branched_on(self.tree, "path") - self.paths
        self.assertEqual(undeclared, set(), f"handled but not in PATHS: {sorted(undeclared)}")

    def test_every_declared_path_is_routed(self):
        # And the other way: a path in the list with no branch answers 400 from
        # the fall-through instead of doing anything.
        unhandled = self.paths - _branched_on(self.tree, "path")
        self.assertEqual(unhandled, set(), f"in PATHS but nothing handles it: {sorted(unhandled)}")


class ThePlaneDoesNotKeepItsOwnCopy(unittest.TestCase):
    """`walkin_plane.API` is ASSIGNED from the routes module, never restated."""

    def test_api_is_derived_and_not_a_literal(self):
        value = _assigned(_tree(PLANE), "API")
        self.assertIsNotNone(value, "walkin_plane.API is gone — the dispatcher filters on it")
        literals = _strings(value)
        self.assertEqual(
            literals,
            set(),
            "walkin_plane.API spells out paths again: "
            f"{sorted(literals)}. Assign it from walkin.routes.PATHS instead — "
            "a second list is how /walkin/engage 404ed in production.",
        )
        self.assertIsInstance(value, ast.Attribute, "API should be `walkin_routes.PATHS`, not a value built here")
        self.assertEqual(value.attr, "PATHS")


class EveryRoutedPathIsReachableBySomebody(unittest.TestCase):
    """The third file: the fence in `auth/gate.py`.

    A path can be routed perfectly and still be unreachable, because the gate's
    default for a stranger and for a walk-in is DENY. This does not assert WHICH
    role reaches which path — that is policy, and it is argued in gate.py's own
    comments — only that no broker route is reachable by nobody at all, which is
    the same silent-404 class of failure seen from the other side.
    """

    def test_no_broker_route_is_fenced_off_from_everyone(self):
        routes = _tree(ROUTES)
        declared = _strings(_assigned(routes, "GET_PATHS")) | _strings(_assigned(routes, "POST_PATHS"))
        gate = _tree(GATE)
        allowed: set[str] = set()
        for name in ("OPEN_PATHS", "ANON_PATHS", "WALKIN_PATHS"):
            value = _assigned(gate, name)
            self.assertIsNotNone(value, f"gate.{name} is gone")
            allowed |= _strings(value)
        unreachable = declared - allowed
        self.assertEqual(
            unreachable,
            set(),
            f"routed but in no allowlist, so no role can call it: {sorted(unreachable)}",
        )


if __name__ == "__main__":
    unittest.main()

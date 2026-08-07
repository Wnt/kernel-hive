"""Unit tests for the auth layer: python3 -m unittest discover -s scripts/serve/auth

Runs on the box (python3-fido2 must be installed). The WebAuthn ceremonies
themselves are not exercised here — those need a real authenticator and are
covered by signing in from a browser — so what is tested is everything that
decides WHO gets in: code parsing, the state file, the invite/bootstrap rules,
the last-admin guard, session lifetime, and the stream ticket's wire format.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import tempfile
import time
import unittest
from pathlib import Path

from fido2.utils import websafe_encode
from fido2.webauthn import AttestedCredentialData

from . import codes, tickets
from .passkeys import credential_to_b64
from .service import AuthError, AuthService, RateLimiter
from .store import AuthStore


class TestCodes(unittest.TestCase):
    def test_generated_code_is_15_chars_in_3_groups(self):
        code = codes.generate()
        self.assertEqual(len(code), 17, code)  # 15 + 2 dashes
        self.assertEqual(codes.normalize(code), code.replace("-", ""))

    def test_normalize_is_forgiving_about_how_it_was_typed(self):
        code = codes.generate()
        canonical = codes.normalize(code)
        for variant in (code.lower(), code.replace("-", ""), f"  {code}  ", code.replace("-", " ")):
            self.assertEqual(codes.normalize(variant), canonical, variant)

    def test_confusable_characters_map_the_crockford_way(self):
        self.assertEqual(codes.normalize("I" * 15), "1" * 15)
        self.assertEqual(codes.normalize("L" * 15), "1" * 15)
        self.assertEqual(codes.normalize("O" * 15), "0" * 15)
        self.assertEqual(codes.normalize("U" * 15), "V" * 15)

    def test_wrong_length_or_charset_is_not_a_code(self):
        for bad in ("", "TOOSHORT", "!" * 15, "0" * 14, "0" * 16):
            self.assertEqual(codes.normalize(bad), "", bad)

    def test_a_junk_code_never_matches_anything(self):
        # The empty-hash trap: hash_code("") must not equal a stored empty hash
        # and must not authenticate.
        self.assertEqual(codes.hash_code("nonsense"), "")
        self.assertFalse(codes.matches("nonsense", ""))
        self.assertFalse(codes.matches("", ""))

    def test_matching_is_by_hash_of_the_canonical_form(self):
        code = codes.generate()
        stored = codes.hash_code(code)
        self.assertTrue(codes.matches(code.lower().replace("-", ""), stored))
        self.assertFalse(codes.matches(codes.generate(), stored))


class StoreCase(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = Path(self.dir.name) / "auth-state.json"

    def tearDown(self):
        self.dir.cleanup()


class TestStore(StoreCase):
    def test_state_file_is_private(self):
        store = AuthStore(self.path)
        store.add_user_with_id("u1", "wnt", "admin")
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_state_survives_a_restart(self):
        store = AuthStore(self.path)
        store.add_user_with_id("u1", "wnt", "admin")
        token = store.new_session("u1", "1.2.3.4", "curl")
        again = AuthStore(self.path)
        self.assertEqual(again.session_user(token)["name"], "wnt")

    def test_a_dated_snapshot_is_kept_before_the_day_s_first_write(self):
        """The account database has no other copy, and passkeys cannot be
        regenerated — a snapshot is the only thing standing between a careless
        delete and everyone being locked out for good."""
        store = AuthStore(self.path)
        store.add_user_with_id("u1", "Jonni", "admin")  # first write: nothing to snapshot yet
        store.add_user_with_id("u2", "guest", "viewer")  # second write: preserves the first state
        snaps = sorted(self.path.parent.glob("auth-state.2*.json"))
        self.assertEqual(len(snaps), 1, snaps)
        preserved = json.loads(snaps[0].read_text())
        self.assertEqual([u["name"] for u in preserved["users"]], ["Jonni"])
        self.assertEqual(snaps[0].stat().st_mode & 0o777, 0o600)

    def test_the_snapshot_is_taken_once_a_day_not_once_a_write(self):
        store = AuthStore(self.path)
        for i in range(5):
            store.add_user_with_id(f"u{i}", f"user{i}", "viewer")
        self.assertEqual(len(list(self.path.parent.glob("auth-state.2*.json"))), 1)

    def test_a_corrupt_state_file_refuses_to_start(self):
        # Silently starting empty would re-open the bootstrap window and let a
        # passer-by claim the gallery.
        self.path.write_text("{not json")
        with self.assertRaises(RuntimeError):
            AuthStore(self.path)

    def test_session_tokens_are_not_stored_in_the_clear(self):
        store = AuthStore(self.path)
        store.add_user_with_id("u1", "wnt", "admin")
        token = store.new_session("u1", "1.2.3.4", "curl")
        self.assertNotIn(token, self.path.read_text())

    def test_expired_sessions_do_not_resolve(self):
        store = AuthStore(self.path)
        store.add_user_with_id("u1", "wnt", "admin")
        token = store.new_session("u1", "1.2.3.4", "curl")
        store._doc["sessions"][0]["expiresAtTs"] = int(time.time()) - 1
        self.assertIsNone(store.session_user(token))

    def test_deleting_a_user_takes_their_passkeys_and_sessions(self):
        store = AuthStore(self.path)
        store.add_user_with_id("u1", "wnt", "admin")
        store.add_credential("u1", "cred1", "ZGF0YQ", "Mac")
        token = store.new_session("u1", "1.2.3.4", "curl")
        store.delete_user("u1")
        self.assertEqual(store.credentials(), [])
        self.assertIsNone(store.session_user(token))

    def test_an_invite_stays_live_after_it_is_claimed(self):
        # It is a LINK: its holder comes back to the same URL until they have a
        # passkey, so being claimed must not retire it. Only expiry does.
        store = AuthStore(self.path)
        inv = store.add_invite("hash1", "guest", "viewer", "u1")
        self.assertTrue(store.claim_invite(inv["tokenHash"], "u2"))
        self.assertEqual([i["usedBy"] for i in store.live_invites()], ["u2"])

    def test_claiming_is_idempotent_so_two_tabs_make_one_person(self):
        store = AuthStore(self.path)
        inv = store.add_invite("hash1", "guest", "viewer", "u1")
        self.assertTrue(store.claim_invite(inv["tokenHash"], "u2"))
        self.assertFalse(store.claim_invite(inv["tokenHash"], "u3"))
        self.assertEqual(store.live_invites()[0]["usedBy"], "u2")

    def test_expired_invites_are_gone_claimed_or_not(self):
        store = AuthStore(self.path)
        store.add_invite("hash1", "guest", "viewer", "u1")
        store.add_invite("hash2", "other", "viewer", "u1")
        store.claim_invite("hash2", "u2")
        for inv in store._doc["invites"]:
            inv["expiresAtTs"] = int(time.time()) - 1
        self.assertEqual(store.live_invites(), [])

    def test_a_session_can_be_capped_below_its_normal_life(self):
        # An account whose only credential is an invite link must not outlive
        # the link: otherwise opening it on the last day buys another 30.
        store = AuthStore(self.path)
        store.add_user_with_id("u1", "Guest", "viewer")
        soon = int(time.time()) + 60
        token = store.new_session("u1", "1.2.3.4", "curl", max_expires_ts=soon)
        self.assertEqual(store._doc["sessions"][0]["expiresAtTs"], soon)
        self.assertIsNotNone(store.session_user(token))
        # …and the cap never EXTENDS a session beyond the normal ceiling.
        store.new_session("u1", "1.2.3.4", "curl", max_expires_ts=int(time.time()) + 10**9)
        self.assertLess(store._doc["sessions"][1]["expiresAtTs"], int(time.time()) + 10**9)


class TestService(StoreCase):
    def service(self):
        return AuthService(self.path, rp_id="example.test", rp_name="t", origin="https://example.test")

    def test_bootstrap_is_minted_once_and_only_while_empty(self):
        svc = self.service()
        token = svc.ensure_bootstrap()
        self.assertTrue(token)
        self.assertIsNone(svc.ensure_bootstrap())  # still pending, not re-minted
        self.assertTrue(svc.public_state(None)["needsBootstrap"])

    def test_the_bootstrap_code_resolves_to_an_admin_invite(self):
        svc = self.service()
        token = svc.ensure_bootstrap()
        invite = svc._resolve_code(token)
        self.assertEqual(invite["kind"], "bootstrap")
        self.assertEqual(invite["role"], "admin")

    def test_a_wrong_code_is_rejected_without_saying_why(self):
        svc = self.service()
        svc.ensure_bootstrap()
        with self.assertRaises(AuthError) as caught:
            svc._resolve_code(codes.generate())
        self.assertEqual(caught.exception.status, 403)
        self.assertEqual(str(caught.exception), "that code is not valid")

    def test_a_spent_bootstrap_token_stops_working(self):
        svc = self.service()
        token = svc.ensure_bootstrap()
        user = svc.store.add_user_with_id("u1", "wnt", "admin")
        svc.store.consume_bootstrap(user["id"])
        with self.assertRaises(AuthError):
            svc._resolve_code(token)
        self.assertFalse(svc.public_state(None)["needsBootstrap"])

    def test_an_invite_carries_its_role_and_name(self):
        svc = self.service()
        admin = svc.store.add_user_with_id("u1", "wnt", "admin")
        issued = svc.create_invite(admin, "Guest", "viewer")
        invite = svc._resolve_code(issued["code"])
        self.assertEqual((invite["kind"], invite["role"], invite["name"]), ("invite", "viewer", "Guest"))

    def test_an_invite_code_is_returned_once_and_never_stored(self):
        svc = self.service()
        admin = svc.store.add_user_with_id("u1", "wnt", "admin")
        issued = svc.create_invite(admin, "Guest", "viewer")
        self.assertNotIn(codes.normalize(issued["code"]), self.path.read_text())

    def test_a_revoked_invite_stops_working(self):
        svc = self.service()
        admin = svc.store.add_user_with_id("u1", "wnt", "admin")
        issued = svc.create_invite(admin, "Guest", "viewer")
        svc.revoke_invite(svc.people()["invites"][0]["id"])
        with self.assertRaises(AuthError):
            svc._resolve_code(issued["code"])

    def test_invites_require_a_name_and_a_real_role(self):
        svc = self.service()
        admin = svc.store.add_user_with_id("u1", "wnt", "admin")
        with self.assertRaises(AuthError):
            svc.create_invite(admin, "  ", "viewer")
        with self.assertRaises(AuthError):
            svc.create_invite(admin, "Guest", "superuser")

    def test_the_last_admin_cannot_be_deleted_or_demoted(self):
        svc = self.service()
        admin = svc.store.add_user_with_id("u1", "wnt", "admin")
        svc.store.add_user_with_id("u2", "guest", "viewer")
        with self.assertRaises(AuthError) as caught:
            svc.delete_user(admin, "u1")
        self.assertEqual(caught.exception.status, 409)
        with self.assertRaises(AuthError):
            svc.set_role(admin, "u1", "viewer")
        # With a second admin in place, both become allowed.
        svc.set_role(admin, "u2", "admin")
        svc.delete_user(admin, "u1")
        self.assertEqual([u["id"] for u in svc.store.users()], ["u2"])

    def test_deleting_your_only_passkey_is_refused(self):
        svc = self.service()
        user = svc.store.add_user_with_id("u1", "wnt", "viewer")
        svc.store.add_credential("u1", "cred1", "ZGF0YQ", "Mac")
        with self.assertRaises(AuthError):
            svc.delete_passkey(user, "cred1", is_admin=False)
        svc.store.add_credential("u1", "cred2", "ZGF0YQ", "iPhone")
        svc.delete_passkey(user, "cred1", is_admin=False)
        self.assertEqual([c["id"] for c in svc.store.credentials("u1")], ["cred2"])

    def test_people_never_leaks_credential_material_or_invite_hashes(self):
        svc = self.service()
        admin = svc.store.add_user_with_id("u1", "wnt", "admin")
        svc.store.add_credential("u1", "cred1", "c2VjcmV0LWtleS1ibG9i", "Mac")
        svc.create_invite(admin, "Guest", "viewer")
        people = svc.people()
        blob = repr(people)
        self.assertNotIn("c2VjcmV0LWtleS1ibG9i", blob)
        self.assertNotIn("tokenHash", blob)
        self.assertEqual(people["users"][0]["passkeys"][0]["label"], "Mac")

    def test_rate_limiting_bounds_guesses(self):
        limiter = RateLimiter(window=60, limit=3)
        for _ in range(3):
            limiter.check("1.2.3.4")
        with self.assertRaises(AuthError) as caught:
            limiter.check("1.2.3.4")
        self.assertEqual(caught.exception.status, 429)
        limiter.check("5.6.7.8")  # a different client is unaffected


class TestDeviceLinks(StoreCase):
    """Linking is the one code that does NOT create an account, so the tests
    that matter are about it staying attached to exactly one existing user."""

    def service(self):
        return AuthService(self.path, rp_id="example.test", rp_name="t", origin="https://example.test")

    def test_a_link_code_resolves_to_its_owner_and_creates_nobody(self):
        svc = self.service()
        user = svc.store.add_user_with_id("u1", "Jonni", "admin")
        issued = svc.create_link(user)
        resolved = svc._resolve_code(issued["code"])
        self.assertEqual(resolved["kind"], "link")
        self.assertEqual(resolved["userId"], "u1")
        self.assertEqual(resolved["name"], "Jonni")
        self.assertEqual(len(svc.store.users()), 1)

    def test_the_qr_encodes_the_code_in_the_fragment(self):
        # The fragment is never sent to a server, which is the whole reason the
        # code goes there rather than in a query string.
        svc = self.service()
        user = svc.store.add_user_with_id("u1", "Jonni", "admin")
        issued = svc.create_link(user)
        self.assertTrue(issued["url"].startswith("https://example.test/link#"))
        self.assertEqual(issued["url"].split("#")[1], codes.normalize(issued["code"]))
        self.assertIn("<svg", issued["qrSvg"])
        self.assertNotIn(codes.normalize(issued["code"]), issued["qrSvg"])

    def test_the_qr_is_rendered_big_enough_to_scan(self):
        """Guards the geometry, not the encoding.

        segno's inline SVG carries width/height but no viewBox, so a symbol
        emitted at scale=1 stays ~41 px wide however the page styles it — it
        renders as a smudge in the corner of the box and no camera will read it.
        This pins the intrinsic size to (modules + 2*border) * scale.
        """
        import re

        import segno

        svc = self.service()
        user = svc.store.add_user_with_id("u1", "Jonni", "admin")
        issued = svc.create_link(user)
        modules = segno.make(issued["url"], error="m").symbol_size(scale=1, border=0)[0]
        expected = (modules + 2 * 2) * 6  # border=2 modules, scale=6 px
        width = int(re.search(r'width="(\d+)"', issued["qrSvg"]).group(1))
        self.assertEqual(width, expected)
        # Pixels per module, not total pixels: the symbol grows with the URL, so
        # a fixed width floor would drift as the origin's name changes. Four is
        # already comfortable for a phone camera; this is at six.
        self.assertGreaterEqual(width / (modules + 4), 4)

    def test_a_link_lasts_about_a_minute(self):
        svc = self.service()
        user = svc.store.add_user_with_id("u1", "Jonni", "admin")
        issued = svc.create_link(user)
        self.assertLessEqual(issued["expiresInSeconds"], 60)
        self.assertGreater(issued["expiresInSeconds"], 50)

    def test_an_expired_link_is_refused(self):
        svc = self.service()
        user = svc.store.add_user_with_id("u1", "Jonni", "admin")
        issued = svc.create_link(user)
        svc.store._doc["links"][0]["expiresAtTs"] = int(time.time()) - 1
        with self.assertRaises(AuthError):
            svc._resolve_code(issued["code"])
        self.assertIsNone(svc.store.consume_link(codes.hash_code(issued["code"])))

    def test_minting_a_new_link_kills_the_previous_one(self):
        svc = self.service()
        user = svc.store.add_user_with_id("u1", "Jonni", "admin")
        first = svc.create_link(user)
        second = svc.create_link(user)
        self.assertEqual(len(svc.store.open_links()), 1)
        with self.assertRaises(AuthError):
            svc._resolve_code(first["code"])
        self.assertEqual(svc._resolve_code(second["code"])["userId"], "u1")

    def test_a_link_is_single_use(self):
        svc = self.service()
        user = svc.store.add_user_with_id("u1", "Jonni", "admin")
        issued = svc.create_link(user)
        token_hash = codes.hash_code(issued["code"])
        self.assertEqual(svc.store.consume_link(token_hash), "u1")
        self.assertIsNone(svc.store.consume_link(token_hash))
        with self.assertRaises(AuthError):
            svc._resolve_code(issued["code"])

    def test_links_are_stored_as_hashes_only(self):
        svc = self.service()
        user = svc.store.add_user_with_id("u1", "Jonni", "admin")
        issued = svc.create_link(user)
        self.assertNotIn(codes.normalize(issued["code"]), self.path.read_text())

    def test_deleting_a_user_kills_their_outstanding_link(self):
        svc = self.service()
        user = svc.store.add_user_with_id("u1", "Jonni", "admin")
        svc.store.add_user_with_id("u2", "other", "admin")
        issued = svc.create_link(user)
        svc.store.delete_user("u1")
        self.assertEqual(svc.store.open_links(), [])
        with self.assertRaises(AuthError):
            svc._resolve_code(issued["code"])

    def test_a_link_ceremony_excludes_the_passkeys_already_on_the_account(self):
        # Otherwise the device that showed the QR could scan it itself and
        # register a duplicate, which is not "another device".
        svc = self.service()
        user = svc.store.add_user_with_id("u1", "Jonni", "admin")
        svc.store.add_credential("u1", "cred1", _stored_credential(), "iPhone")
        issued = svc.create_link(user)
        _cid, options = svc.begin_redeem(issued["code"], "", "1.2.3.4")
        # The ceremony carries the EXISTING account's id, not a fresh one.
        self.assertEqual(options["user"]["id"], websafe_encode(b"u1"))
        self.assertEqual(len(options["excludeCredentials"]), 1)

    def test_an_invite_still_creates_a_separate_account(self):
        # The regression this whole feature exists to avoid: two Jonnis.
        svc = self.service()
        admin = svc.store.add_user_with_id("u1", "Jonni", "admin")
        issued = svc.create_invite(admin, "Jonni", "viewer")
        self.assertEqual(svc._resolve_code(issued["code"])["kind"], "invite")


class TestInviteLinks(StoreCase):
    """The invite as a LINK: it lets its holder in with no passkey at all, and
    keeps working until it expires."""

    def service(self) -> AuthService:
        return AuthService(self.path, "example.test", "Gallery", "https://example.test")

    def _issued(self, svc: AuthService, name: str = "Guest", role: str = "viewer") -> dict:
        admin = svc.store.add_user_with_id("u1", "Root", "admin")
        return svc.create_invite(admin, name, role)

    def test_the_url_carries_the_code_in_the_fragment(self):
        # A fragment is never sent to a server: not in the access log, not in a
        # Referer, not in any proxy between. That matters more here than for a
        # device link, because this URL is meant to be KEPT.
        svc = self.service()
        issued = self._issued(svc)
        self.assertEqual(issued["url"], f"https://example.test/login#{issued['code']}")

    def test_entering_creates_the_account_with_no_passkey(self):
        svc = self.service()
        issued = self._issued(svc, "Guest", "viewer")
        user, token, info = svc.enter_invite(issued["code"], "1.2.3.4", "curl")
        self.assertEqual((user["name"], user["role"]), ("Guest", "viewer"))
        self.assertEqual(svc.store.credentials(user["id"]), [])
        self.assertEqual(svc.store.session_user(token)["id"], user["id"])
        self.assertFalse(info["returning"])
        self.assertFalse(info["hasPasskey"])

    def test_reopening_the_link_returns_the_SAME_person(self):
        # Not a second account with the same name — the bug the whole invite
        # design exists to avoid, now reachable by simply refreshing.
        svc = self.service()
        issued = self._issued(svc)
        first, _t1, _i1 = svc.enter_invite(issued["code"], "1.2.3.4", "curl")
        again, _t2, info = svc.enter_invite(issued["code"], "1.2.3.4", "curl")
        self.assertEqual(first["id"], again["id"])
        self.assertEqual(len(svc.store.users()), 2)  # the admin, and the guest
        self.assertTrue(info["returning"])

    def test_a_passkey_less_session_cannot_outlive_the_invite(self):
        svc = self.service()
        issued = self._issued(svc)
        _u, _t, _i = svc.enter_invite(issued["code"], "1.2.3.4", "curl")
        expiry = svc.store._doc["invites"][0]["expiresAtTs"]
        self.assertLessEqual(svc.store._doc["sessions"][0]["expiresAtTs"], expiry)

    def test_a_passkey_frees_the_session_from_the_invite(self):
        svc = self.service()
        issued = self._issued(svc)
        user, _t, _i = svc.enter_invite(issued["code"], "1.2.3.4", "curl")
        svc.store.add_credential(user["id"], "cred1", _stored_credential(), "iPhone")
        _u2, _t2, info = svc.enter_invite(issued["code"], "1.2.3.4", "curl")
        self.assertTrue(info["hasPasskey"])
        expiry = svc.store._doc["invites"][0]["expiresAtTs"]
        self.assertGreater(svc.store._doc["sessions"][-1]["expiresAtTs"], expiry)

    def test_an_expired_link_lets_nobody_in(self):
        svc = self.service()
        issued = self._issued(svc)
        svc.store._doc["invites"][0]["expiresAtTs"] = int(time.time()) - 1
        with self.assertRaises(AuthError) as caught:
            svc.enter_invite(issued["code"], "1.2.3.4", "curl")
        self.assertEqual(caught.exception.status, 403)

    def test_a_revoked_link_lets_nobody_in(self):
        svc = self.service()
        issued = self._issued(svc)
        svc.revoke_invite(svc.store._doc["invites"][0]["tokenHash"][:16])
        with self.assertRaises(AuthError):
            svc.enter_invite(issued["code"], "1.2.3.4", "curl")

    def test_deleting_the_person_kills_their_link(self):
        # Otherwise the same URL would silently re-create the account an admin
        # had just removed, and the removal would mean nothing.
        svc = self.service()
        issued = self._issued(svc)
        user, _t, _i = svc.enter_invite(issued["code"], "1.2.3.4", "curl")
        svc.store.delete_user(user["id"])
        with self.assertRaises(AuthError):
            svc.enter_invite(issued["code"], "1.2.3.4", "curl")

    def test_days_left_counts_the_part_day_as_one(self):
        svc = self.service()
        issued = self._issued(svc)
        svc.store._doc["invites"][0]["expiresAtTs"] = int(time.time()) + 3600
        _u, _t, info = svc.enter_invite(issued["code"], "1.2.3.4", "curl")
        self.assertEqual(info["daysLeft"], 1)

    def test_a_junk_code_opens_nothing(self):
        svc = self.service()
        self._issued(svc)
        for junk in ("", "nope", codes.generate()):
            with self.assertRaises(AuthError):
                svc.enter_invite(junk, "1.2.3.4", "curl")

    def test_an_invite_code_is_refused_by_the_ceremony_path(self):
        # There is exactly ONE way an invite is used, so a stale client cannot
        # take the old route and create a second account from the same link.
        svc = self.service()
        issued = self._issued(svc)
        with self.assertRaises(AuthError):
            svc.begin_redeem(issued["code"], "", "1.2.3.4")

    def test_the_admin_list_says_whether_a_link_is_in_use(self):
        svc = self.service()
        issued = self._issued(svc)
        self.assertEqual([i["claimed"] for i in svc.people()["invites"]], [False])
        svc.enter_invite(issued["code"], "1.2.3.4", "curl")
        self.assertEqual([i["claimed"] for i in svc.people()["invites"]], [True])


def _stored_credential() -> str:
    """A credential in exactly the form the store holds, built by fido2 itself
    so the exclude-list test exercises the real parsing path."""
    from fido2.cose import ES256

    key = ES256.from_ctap1(b"\x04" + bytes(range(64)))
    return credential_to_b64(AttestedCredentialData.create(b"\x00" * 16, b"cred-1", key))


class TestStreamTickets(unittest.TestCase):
    """The Python minter and the Rust verifier (streamhost/src/session_ticket.rs)
    are two halves of one wire format; this pins the half we can test here."""

    KEY = b"a-shared-secret-between-gateway-and-streamhost"

    def verify_like_rust(self, path: str, tile: str, key: bytes, now: int) -> bool:
        ticket = path.removeprefix("/wt/")
        exp, nonce, sig = ticket.split(".")
        if now > int(exp) or int(exp) > now + 3600:
            return False
        msg = f"v1|{tile}|{exp}|{nonce}".encode()
        want = base64.urlsafe_b64encode(hmac.new(key, msg, hashlib.sha256).digest()).rstrip(b"=").decode()
        return hmac.compare_digest(want, sig)

    def test_a_minted_ticket_verifies(self):
        path = tickets.mint(self.KEY, "win95")
        self.assertTrue(path.startswith("/wt/"))
        self.assertTrue(self.verify_like_rust(path, "win95", self.KEY, int(time.time())))

    def test_a_ticket_is_bound_to_its_tile(self):
        path = tickets.mint(self.KEY, "win95")
        self.assertFalse(self.verify_like_rust(path, "solariscde", self.KEY, int(time.time())))

    def test_a_ticket_is_bound_to_the_key(self):
        path = tickets.mint(self.KEY, "win95")
        self.assertFalse(self.verify_like_rust(path, "win95", b"other-key", int(time.time())))

    def test_a_ticket_expires(self):
        path = tickets.mint(self.KEY, "win95", ttl_secs=10)
        self.assertFalse(self.verify_like_rust(path, "win95", self.KEY, int(time.time()) + 11))

    def test_the_nonce_stays_inside_the_charset_the_verifier_accepts(self):
        for _ in range(200):
            nonce = tickets.mint(self.KEY, "win95").split(".")[1]
            self.assertTrue(all(c.isalnum() or c in "-_" for c in nonce), nonce)
            self.assertTrue(0 < len(nonce) <= 64)

    def test_every_ticket_is_unique(self):
        minted = {tickets.mint(self.KEY, "win95") for _ in range(50)}
        self.assertEqual(len(minted), 50)


if __name__ == "__main__":
    unittest.main()

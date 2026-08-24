"""Auth policy: who may enter, who may invite, what a session means.

The split is deliberate — store.py knows how to persist, passkeys.py knows
WebAuthn, and this module is the only place that decides. Everything that could
be phrased as a rule about people lives here.

The rules:
  * The first person in is whoever redeems the one-time bootstrap token, and
    they are an admin. That token exists exactly once per deployment and is
    burned on use, so the "anyone can claim an empty gallery" window closes the
    moment it is used rather than staying open until someone remembers.
  * Everyone after that needs an invite an admin created. The name and role are
    baked into the invite, so redeeming it cannot promote anybody.
  * A role is admin or viewer. Viewers get the gallery; admins also get the
    people-management surface.
  * The last admin cannot be deleted or demoted. A gallery with no admin can
    only be repaired by hand-editing the state file on the box.
"""

from __future__ import annotations

import sys
import threading
import time
from pathlib import Path

from . import codes
from .passkeys import Ceremonies, credential_from_b64, credential_id_b64, credential_to_b64
from .store import AuthStore

# Redemption and login are the two unauthenticated surfaces; both are bounded
# per client so a stolen-looking code cannot be ground down by brute force. An
# invite code is 75 bits, so this is belt-and-braces rather than the real
# defence — but it also keeps a broken client from hammering labhost.
RATE_WINDOW_SECS = 60
RATE_MAX_ATTEMPTS = 10


class AuthError(Exception):
    """A failure that is safe to show a caller. Anything else is a 500."""

    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


def _log_ceremony_failure(what: str, exc: Exception) -> None:
    """The caller is told only that it failed; the operator needs to know why.

    A rejected ceremony is otherwise a dead end to debug — the browser reports a
    generic error and so does the response, by design. Nothing here is secret:
    it is a verification failure on a credential the caller supplied.
    """
    sys.stderr.write(f"[auth] {what} rejected: {type(exc).__name__}: {exc}\n")


class RateLimiter:
    def __init__(self, window: int = RATE_WINDOW_SECS, limit: int = RATE_MAX_ATTEMPTS):
        self.window = window
        self.limit = limit
        self._hits: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def check(self, key: str) -> None:
        t = time.time()
        with self._lock:
            hits = [h for h in self._hits.get(key, []) if t - h < self.window]
            if len(hits) >= self.limit:
                self._hits[key] = hits
                raise AuthError("too many attempts; wait a minute", status=429)
            hits.append(t)
            self._hits[key] = hits


class AuthService:
    def __init__(self, state_path: Path, rp_id: str, rp_name: str, origin: str, usage=None):
        self.store = AuthStore(state_path)
        self.ceremonies = Ceremonies(rp_id, rp_name, origin)
        self.limiter = RateLimiter()
        self.origin = origin
        # serve/usage.py's counter store, or None where nobody is counting (the
        # auth tests). Held only so that removing a person removes their
        # per-person counters with them — the identity and the tally of what
        # that identity did are deleted by the same click, or the deletion is a
        # half-truth.
        self.usage = usage

    # ---- bootstrap ---------------------------------------------------------

    def ensure_bootstrap(self) -> str | None:
        """Mint the one-time master token if this deployment has no way in yet.

        Returns the plaintext token exactly once, for the caller to show the
        operator; only its hash is kept. A deployment that already has a user,
        or an unused token, gets None.
        """
        if self.store.users() or self.store.bootstrap_pending():
            return None
        token = codes.generate()
        self.store.set_bootstrap(codes.hash_code(token))
        return token

    def reset_bootstrap(self) -> str:
        """Mint a fresh master token, invalidating any outstanding one. The
        recovery path for a lost token or a gallery locked out of its admins."""
        token = codes.generate()
        self.store.set_bootstrap(codes.hash_code(token))
        return token

    # ---- session-facing state ---------------------------------------------

    def public_state(self, user: dict | None) -> dict:
        return {
            "authenticated": bool(user),
            "user": {"id": user["id"], "name": user["name"], "role": user["role"]} if user else None,
            "needsBootstrap": self.store.bootstrap_pending() and not self.store.users(),
        }

    def user_for_token(self, token: str) -> dict | None:
        return self.store.session_user(token)

    # ---- redeeming an invite (bootstrap or ordinary) -----------------------

    def _resolve_code(self, code: str) -> dict:
        """Which invite (if any) a typed code opens. Never says which kind of
        code was wrong — a caller learns only that it did not work."""
        canonical = codes.hash_code(code)
        if not canonical:
            raise AuthError("that code is not valid", status=403)
        boot = self.store.bootstrap_hash()
        if boot and codes.matches(code, boot):
            return {"kind": "bootstrap", "tokenHash": canonical, "role": "admin", "name": None}
        for inv in self.store.live_invites():
            if codes.matches(code, inv["tokenHash"]):
                return {"kind": "invite", "tokenHash": canonical, "role": inv["role"], "name": inv["name"]}
        # A device link is the one code that does NOT create an account: it adds
        # a passkey to the one that minted it.
        for link in self.store.open_links():
            if codes.matches(code, link["tokenHash"]):
                owner = self.store.user(link["userId"])
                if owner:
                    return {"kind": "link", "tokenHash": canonical, "userId": owner["id"], "name": owner["name"]}
        raise AuthError("that code is not valid", status=403)

    def begin_redeem(self, code: str, name: str, client_ip: str) -> tuple[str, dict]:
        self.limiter.check(f"redeem:{client_ip}")
        invite = self._resolve_code(code)
        if invite["kind"] == "invite":
            # An ordinary invite does not come through here any more: it is a
            # LINK that lets its holder in without a passkey (enter_invite), and
            # the passkey is then offered on top through the ordinary add-a-key
            # path. Only the bootstrap token and a device link still REQUIRE a
            # ceremony — the first admin must end up with a way to sign in, and
            # a device link exists for no other purpose.
            raise AuthError("open the invite link to use that code", status=400)
        display = (invite["name"] or name or "").strip() or "admin"
        if invite["kind"] == "link":
            # Linking a device registers a SECOND passkey on an account that
            # already exists, so the ceremony must carry that account's id (the
            # authenticator signs it in) and must exclude the passkeys it
            # already holds — otherwise the device that minted the code could
            # enrol itself again and call it a new device.
            uid = invite["userId"]
            existing = [credential_from_b64(c["data"]) for c in self.store.credentials(uid)]
        else:
            # The user id is minted BEFORE the ceremony, not at completion: the
            # authenticator signs it into the credential, so it has to exist
            # first. The user row itself is only written once the passkey
            # verifies, so an abandoned ceremony leaves nothing behind.
            uid = _new_user_id()
            existing = []
        meta = {"invite": invite, "name": display, "userId": uid}
        return self.ceremonies.begin_registration(
            user_id=uid.encode("ascii"),
            name=display,
            display_name=display,
            existing=existing,
            meta=meta,
        )

    def finish_redeem(self, cid: str, response: dict, ip: str, user_agent: str) -> tuple[dict, str]:
        try:
            cred, meta = self.ceremonies.finish_registration(cid, response)
        except AuthError:
            raise
        except Exception as exc:
            _log_ceremony_failure("registration", exc)
            raise AuthError("passkey registration failed", status=400) from exc
        invite = meta["invite"]

        # A device link spends its code at COMPLETION, not at begin: an
        # abandoned ceremony must leave the code usable, and a completed one
        # must not be replayable. consume_link does both atomically, and it is
        # also the expiry check — a code that lapsed mid-ceremony is gone.
        if invite["kind"] == "link":
            owner_id = self.store.consume_link(invite["tokenHash"])
            if not owner_id or owner_id != meta["userId"]:
                raise AuthError("that code has expired — generate a new one", status=403)
            owner = self.store.user(owner_id)
            if not owner:
                raise AuthError("that code is not valid", status=403)
            self.store.add_credential(
                owner["id"], credential_id_b64(cred), credential_to_b64(cred), _device_label(user_agent)
            )
            return owner, self.store.new_session(owner["id"], ip, user_agent)

        # Re-check the token at COMPLETION, not just at begin: a ceremony can
        # sit open for minutes, and the token may have been spent in between.
        if not self.store.bootstrap_pending():
            raise AuthError("that code is not valid", status=403)

        user = self.store.add_user_with_id(meta["userId"], meta["name"], invite["role"])
        self.store.add_credential(
            user["id"], credential_id_b64(cred), credential_to_b64(cred), _device_label(user_agent)
        )
        self.store.consume_bootstrap(user["id"])
        token = self.store.new_session(user["id"], ip, user_agent)
        return user, token

    # ---- entering on an invite LINK ----------------------------------------

    def enter_invite(self, code: str, ip: str, user_agent: str) -> tuple[dict, str, dict]:
        """Let an invite's holder in, with or without a passkey.

        This is the whole shape of the invite flow now. The link IS the
        credential: opening it creates the account on first use and signs the
        holder in every time, so a visitor who does not want a passkey — or
        whose browser cannot make one — is not shut out. A passkey is then
        offered on top, every visit, because it is what survives the invite.

        WHAT THIS COSTS, stated plainly: an invite URL is a bearer token for as
        long as it lives, so anyone it is forwarded to gets in as that person.
        Three things bound that. It expires (INVITE_TTL_SECS, 7 days), and the
        admin can revoke it before then. The session it mints is capped at the
        invite's own expiry while the account has no passkey, so access cannot
        outlive the link that granted it. And the code rides the URL FRAGMENT,
        which browsers never send — it stays out of the access log, out of any
        Referer, and out of every proxy in between.
        """
        self.limiter.check(f"enter:{ip}")
        if not codes.hash_code(code):
            raise AuthError("that code is not valid", status=403)
        invite = next((i for i in self.store.live_invites() if codes.matches(code, i["tokenHash"])), None)
        if not invite:
            raise AuthError("that invite link is not valid or has expired", status=403)

        claimed_by = invite.get("usedBy")
        user = self.store.user(claimed_by) if claimed_by else None
        if claimed_by and not user:
            # The account this invite made has since been deleted. Re-creating
            # it here would undo an admin's removal with the same old link, so
            # the link dies with the person.
            raise AuthError("that invite link is not valid or has expired", status=403)

        returning = user is not None
        if not user:
            user = self.store.add_user_with_id(_new_user_id(), invite["name"], invite["role"])
            self.store.claim_invite(invite["tokenHash"], user["id"])

        has_passkey = bool(self.store.credentials(user["id"]))
        expires_ts = int(invite.get("expiresAtTs", 0))
        token = self.store.new_session(user["id"], ip, user_agent, max_expires_ts=None if has_passkey else expires_ts)
        return (
            user,
            token,
            {
                "returning": returning,
                "hasPasskey": has_passkey,
                "expiresAt": invite.get("expiresAt", ""),
                "daysLeft": _days_left(expires_ts),
            },
        )

    # ---- login -------------------------------------------------------------

    def begin_login(self, client_ip: str) -> tuple[str, dict]:
        self.limiter.check(f"login:{client_ip}")
        creds = [credential_from_b64(c["data"]) for c in self.store.credentials()]
        if not creds:
            raise AuthError("no passkeys are registered yet", status=403)
        return self.ceremonies.begin_authentication(creds)

    def finish_login(self, cid: str, response: dict, ip: str, user_agent: str) -> tuple[dict, str]:
        records = self.store.credentials()
        creds = [credential_from_b64(c["data"]) for c in records]
        try:
            matched = self.ceremonies.finish_authentication(cid, response, creds)
        except Exception as exc:
            _log_ceremony_failure("authentication", exc)
            raise AuthError("that passkey was not accepted", status=403) from exc
        cred_id = credential_id_b64(matched)
        record = next((c for c in records if c["id"] == cred_id), None)
        if not record:
            raise AuthError("that passkey was not accepted", status=403)
        user = self.store.user(record["userId"])
        if not user:
            # The credential outlived its user: treat as revoked, and clean up.
            self.store.delete_credential(cred_id)
            raise AuthError("that passkey was not accepted", status=403)
        self.store.touch_credential(cred_id)
        return user, self.store.new_session(user["id"], ip, user_agent)

    # ---- adding a passkey to the signed-in account -------------------------

    def begin_add_passkey(self, user: dict) -> tuple[str, dict]:
        existing = [credential_from_b64(c["data"]) for c in self.store.credentials(user["id"])]
        return self.ceremonies.begin_registration(
            user_id=user["id"].encode("ascii"),
            name=user["name"],
            display_name=user["name"],
            existing=existing,
            meta={"userId": user["id"]},
        )

    def finish_add_passkey(self, cid: str, response: dict, user: dict, user_agent: str) -> dict:
        try:
            cred, meta = self.ceremonies.finish_registration(cid, response)
        except Exception as exc:
            _log_ceremony_failure("passkey add", exc)
            raise AuthError("passkey registration failed", status=400) from exc
        if meta.get("userId") != user["id"]:
            raise AuthError("passkey registration failed", status=400)
        return self.store.add_credential(
            user["id"], credential_id_b64(cred), credential_to_b64(cred), _device_label(user_agent)
        )

    # ---- linking another device --------------------------------------------

    def create_link(self, user: dict) -> dict:
        """A one-minute, single-use code that adds a passkey to `user`.

        Returned with the QR a second device scans. The code is in the URL's
        FRAGMENT, which browsers never send to a server — so it stays out of the
        access log, out of Referer headers, and out of anything between the two
        devices. The page on the far side reads it in JavaScript and posts it
        back over TLS.
        """
        token = codes.generate()
        link = self.store.add_link(codes.hash_code(token), user["id"])
        url = f"{self.origin}/link#{codes.normalize(token)}"
        return {
            "code": token,
            "url": url,
            "qrSvg": _qr_svg(url),
            "expiresInSeconds": max(0, link["expiresAtTs"] - int(time.time())),
        }

    # ---- admin surface -----------------------------------------------------

    def create_invite(self, admin: dict, name: str, role: str) -> dict:
        name = (name or "").strip()
        if not name:
            raise AuthError("a name is required")
        if role not in ("admin", "viewer"):
            raise AuthError("role must be admin or viewer")
        token = codes.generate()
        inv = self.store.add_invite(codes.hash_code(token), name, role, admin["id"])
        # The plaintext is returned exactly once, here. It is not stored, so a
        # lost code is re-issued rather than recovered.
        #
        # The URL carries it in the FRAGMENT, which browsers never send to any
        # server: it is therefore absent from the access log, from every Referer
        # and from anything that proxied the request. That matters more here
        # than it does for a device link, because this URL is meant to be KEPT —
        # its holder comes back to it until they make a passkey.
        return {
            "code": token,
            "url": f"{self.origin}/login#{token}",
            "name": inv["name"],
            "role": inv["role"],
            "expiresAt": inv["expiresAt"],
        }

    def people(self) -> dict:
        users = self.store.users()
        creds = self.store.credentials()
        for u in users:
            u["passkeys"] = [
                {"id": c["id"], "label": c["label"], "createdAt": c["createdAt"], "lastUsedAt": c["lastUsedAt"]}
                for c in creds
                if c["userId"] == u["id"]
            ]
        # Claimed invites are listed too, and say so: a link stays usable until
        # it expires, so "somebody has already been in on this one" is a fact
        # the admin needs in order to decide whether to revoke it early.
        invites = [
            {
                "id": i["tokenHash"][:16],
                "name": i["name"],
                "role": i["role"],
                "createdAt": i["createdAt"],
                "expiresAt": i["expiresAt"],
                "claimed": bool(i.get("usedAt")),
            }
            for i in self.store.live_invites()
        ]
        return {"users": users, "invites": invites}

    def scoreboard(self) -> dict:
        """Per-person interaction counts, joined to names. ADMIN CALLERS ONLY —
        routes.py enforces that; this method exists so the join to the user list
        happens in one place."""
        if self.usage is None:
            return {"users": [], "stations": {}}
        return self.usage.scoreboard(self.store.users())

    def delete_user(self, admin: dict, user_id: str) -> None:
        target = self.store.user(user_id)
        if not target:
            raise AuthError("no such user", status=404)
        if target["role"] == "admin" and self.store.admin_count() <= 1:
            raise AuthError("that is the last admin — promote someone else first", status=409)
        self.store.delete_user(user_id)
        if self.usage is not None:
            self.usage.forget_user(user_id)

    def set_role(self, admin: dict, user_id: str, role: str) -> None:
        target = self.store.user(user_id)
        if not target:
            raise AuthError("no such user", status=404)
        if target["role"] == "admin" and role != "admin" and self.store.admin_count() <= 1:
            raise AuthError("that is the last admin — promote someone else first", status=409)
        if not self.store.set_role(user_id, role):
            raise AuthError("role must be admin or viewer")

    def revoke_invite(self, invite_id: str) -> None:
        for inv in self.store.invites():
            if inv["tokenHash"][:16] == invite_id:
                self.store.revoke_invite(inv["tokenHash"])
                return
        raise AuthError("no such invite", status=404)

    def delete_passkey(self, user: dict, cred_id: str, is_admin: bool) -> None:
        owner = None if is_admin else user["id"]
        remaining = [c for c in self.store.credentials(user["id"]) if c["id"] != cred_id]
        if not is_admin and not remaining:
            raise AuthError("that is your only passkey — add another first", status=409)
        if not self.store.delete_credential(cred_id, owner):
            raise AuthError("no such passkey", status=404)


def _qr_svg(url: str) -> str:
    """The link URL as an inline SVG.

    Rendered here rather than in the browser so the page needs no QR library and
    no canvas; it arrives inside the same JSON as the code, so the secret is
    never a separate image request that could be cached or logged. Error
    correction stays at the default: a screen-to-camera scan does not need the
    redundancy a printed label would.
    """
    import segno

    # svg_inline, not save(): it returns a str with no XML declaration, ready to
    # drop straight into the page's DOM.
    #
    # scale=6 matters. The emitted SVG carries width/height but NO viewBox, so
    # CSS can only stretch the box, not the drawing — a scale=1 symbol stays 41
    # px wide in the corner of whatever element holds it. Scaling here gives the
    # element its true intrinsic size and the page needs no sizing rules.
    return segno.make(url, error="m").svg_inline(scale=6, border=2)


def _new_user_id() -> str:
    import secrets

    return secrets.token_hex(16)


def _days_left(expires_ts: int) -> int:
    """Whole days an invite still has, rounded UP so the last part-day counts as
    one — telling somebody "0 days left" while the link still works reads as
    broken, and a day they do not have would be worse."""
    import math

    return max(0, math.ceil((expires_ts - time.time()) / 86400))


def _device_label(user_agent: str) -> str:
    """A human hint for the passkey list. Not identity, not security — just
    enough to tell "my phone" from "the laptop" when revoking one."""
    ua = user_agent or ""
    for needle, label in (
        ("iPhone", "iPhone"),
        ("iPad", "iPad"),
        ("Android", "Android"),
        ("Macintosh", "Mac"),
        ("Windows", "Windows"),
        ("Linux", "Linux"),
    ):
        if needle in ua:
            return label
    return "passkey"

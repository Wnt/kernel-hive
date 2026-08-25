"""Persistent auth state: users, their passkeys, outstanding invites, sessions.

One JSON file, 0600, rewritten atomically (tmp + os.replace) under one lock —
ThreadingHTTPServer serves each connection on its own thread, so every read or
write here is concurrent with another one. The whole document lives in memory
between writes; it holds tens of records for a private gallery, never thousands.

Nothing secret is stored in the clear. Invite codes are SHA-256 hashes (see
codes.py) and a session cookie is stored as the SHA-256 of the token the browser
holds, so possession of this file lets nobody log in or redeem an invite. The
passkey public keys are, by definition, public.
"""

from __future__ import annotations

import copy
import json
import os
import secrets
import shutil
import threading
import time
from contextlib import contextmanager
from pathlib import Path

SESSION_TTL_SECS = 30 * 24 * 3600
INVITE_TTL_SECS = 7 * 24 * 3600
# A device-link code adds a passkey to an EXISTING account, so it is worth more
# than an invite: it hands over one person's identity rather than creating a new
# one. It is meant to be scanned off a screen that is in front of you right now,
# so a minute is generous — and the owner can mint another with one click.
LINK_TTL_SECS = 60
# How stale a session's `lastSeenAt` may get before a request rewrites it. See
# AuthStore.session_user: the touch is on the hot path of every gated request.
SEEN_TOUCH_SECS = 300
# Dated copies of the state file kept beside it (see _snapshot).
SNAPSHOT_KEEP = 14
# `walkin` is a self-registered account (docs/lab/WALKIN-BRIEF.md §5). It is a
# role like any other here — the fencing that makes it different lives in
# gate.py, not in what the store will persist.
ROLES = ("admin", "viewer", "walkin")
# The walk-in switch and its account index, persisted so that a service
# restart cannot silently re-open the plane (walkin.py owns the semantics).
WALKIN_DEFAULTS: dict = {"access": "closed", "drain": False, "accounts": {}, "audit": []}


def now() -> int:
    return int(time.time())


def iso(ts: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def _token_hash(token: str) -> str:
    import hashlib

    return hashlib.sha256(token.encode("ascii")).hexdigest()


class AuthStore:
    """The auth state file. Every public method is safe to call from any thread."""

    def __init__(self, path: Path):
        self.path = Path(path)
        self._lock = threading.RLock()
        self._doc = self._read()

    # ---- persistence -------------------------------------------------------

    def _read(self) -> dict:
        try:
            doc = json.loads(self.path.read_text())
        except FileNotFoundError:
            doc = {}
        except Exception:
            # A corrupt state file must not silently become an empty one: that
            # would re-open the bootstrap window and let anyone claim the
            # gallery. Refuse to start instead.
            raise RuntimeError(f"auth state at {self.path} is unreadable — refusing to start with no users") from None
        doc.setdefault("version", 1)
        for key in ("users", "credentials", "invites", "links", "sessions"):
            doc.setdefault(key, [])
        doc.setdefault("bootstrap", None)
        _migrate_walkin(doc)
        return doc

    def _snapshot(self) -> None:
        """Keep a dated copy of the state before the first write of each day.

        This file IS the account database: the passkey public keys, and nothing
        else, are what let people in. There is no other copy and no way to
        regenerate one — delete it and every enrolled device is locked out
        permanently, which is exactly what happened on 2026-08-05 while the
        destructive e2e suite was being run against the live gallery. A day's
        granularity is enough to undo that class of mistake.
        """
        if not self.path.exists():
            return
        stamp = time.strftime("%Y-%m-%d", time.gmtime())
        snap = self.path.with_name(f"{self.path.stem}.{stamp}{self.path.suffix}")
        if snap.exists():
            return
        try:
            shutil.copy2(self.path, snap)
            os.chmod(snap, 0o600)
            kept = sorted(self.path.parent.glob(f"{self.path.stem}.2[0-9][0-9][0-9]-*{self.path.suffix}"))
            for stale in kept[:-SNAPSHOT_KEEP]:
                stale.unlink(missing_ok=True)
        except OSError:
            # A snapshot is a safety net, not a precondition: failing to take
            # one must never stop somebody signing in.
            pass

    def _write(self) -> None:
        self._snapshot()
        tmp = self.path.with_suffix(".tmp")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        # Create with 0600 from the start — never a window where the file exists
        # world-readable and is chmod'ed a moment later.
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump(self._doc, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, self.path)

    # ---- bootstrap ---------------------------------------------------------

    def bootstrap_pending(self) -> bool:
        """True while the one-time master token is still redeemable."""
        with self._lock:
            b = self._doc.get("bootstrap")
            return bool(b) and not b.get("usedAt")

    def set_bootstrap(self, token_hash: str) -> None:
        with self._lock:
            self._doc["bootstrap"] = {"tokenHash": token_hash, "createdAt": iso(now()), "usedAt": None}
            self._write()

    def bootstrap_hash(self) -> str:
        with self._lock:
            b = self._doc.get("bootstrap") or {}
            return "" if b.get("usedAt") else (b.get("tokenHash") or "")

    def consume_bootstrap(self, user_id: str) -> None:
        with self._lock:
            b = self._doc.get("bootstrap")
            if b:
                b["usedAt"] = iso(now())
                b["usedBy"] = user_id
                self._write()

    # ---- users -------------------------------------------------------------

    def users(self) -> list[dict]:
        with self._lock:
            return [dict(u) for u in self._doc["users"]]

    def user(self, user_id: str) -> dict | None:
        with self._lock:
            for u in self._doc["users"]:
                if u["id"] == user_id:
                    return dict(u)
        return None

    def add_user_with_id(self, user_id: str, name: str, role: str) -> dict:
        """Insert a user under an id chosen by the caller.

        The id is not generated here because WebAuthn signs it into the
        credential during registration, so it must exist before the ceremony
        starts — while the user row itself must not, or an abandoned ceremony
        would leave a passkey-less ghost account behind.
        """
        with self._lock:
            for u in self._doc["users"]:
                if u["id"] == user_id:
                    return dict(u)
            user = {
                "id": user_id,
                "name": name,
                "role": role if role in ROLES else "viewer",
                "createdAt": iso(now()),
                "lastSeenAt": None,
            }
            self._doc["users"].append(user)
            self._write()
            return dict(user)

    def set_role(self, user_id: str, role: str) -> bool:
        if role not in ROLES:
            return False
        with self._lock:
            for u in self._doc["users"]:
                if u["id"] == user_id:
                    u["role"] = role
                    self._write()
                    return True
        return False

    def delete_user(self, user_id: str) -> bool:
        """Remove a user with their passkeys and sessions — one call, so a
        deleted user can never keep streaming on a session we forgot to drop."""
        with self._lock:
            before = len(self._doc["users"])
            self._doc["users"] = [u for u in self._doc["users"] if u["id"] != user_id]
            if len(self._doc["users"]) == before:
                return False
            self._doc["credentials"] = [c for c in self._doc["credentials"] if c["userId"] != user_id]
            self._doc["sessions"] = [s for s in self._doc["sessions"] if s["userId"] != user_id]
            self._doc["links"] = [link for link in self._doc["links"] if link["userId"] != user_id]
            self._write()
            return True

    def admin_count(self) -> int:
        with self._lock:
            return sum(1 for u in self._doc["users"] if u["role"] == "admin")

    # ---- credentials (passkeys) --------------------------------------------

    def credentials(self, user_id: str | None = None) -> list[dict]:
        with self._lock:
            return [dict(c) for c in self._doc["credentials"] if user_id is None or c["userId"] == user_id]

    def add_credential(self, user_id: str, cred_id: str, data_b64: str, label: str) -> dict:
        with self._lock:
            cred = {
                "id": cred_id,
                "userId": user_id,
                "data": data_b64,
                "label": label,
                "createdAt": iso(now()),
                "lastUsedAt": None,
            }
            self._doc["credentials"].append(cred)
            self._write()
            return dict(cred)

    def touch_credential(self, cred_id: str) -> None:
        with self._lock:
            for c in self._doc["credentials"]:
                if c["id"] == cred_id:
                    c["lastUsedAt"] = iso(now())
                    self._write()
                    return

    def delete_credential(self, cred_id: str, user_id: str | None = None) -> bool:
        with self._lock:
            keep = [
                c
                for c in self._doc["credentials"]
                if not (c["id"] == cred_id and (user_id is None or c["userId"] == user_id))
            ]
            if len(keep) == len(self._doc["credentials"]):
                return False
            self._doc["credentials"] = keep
            self._write()
            return True

    # ---- invites -----------------------------------------------------------

    def invites(self) -> list[dict]:
        with self._lock:
            self._prune()
            return [dict(i) for i in self._doc["invites"]]

    def add_invite(self, token_hash: str, name: str, role: str, created_by: str) -> dict:
        with self._lock:
            inv = {
                "tokenHash": token_hash,
                "name": name,
                "role": role if role in ROLES else "viewer",
                "createdBy": created_by,
                "createdAt": iso(now()),
                "expiresAt": iso(now() + INVITE_TTL_SECS),
                "expiresAtTs": now() + INVITE_TTL_SECS,
                "usedAt": None,
            }
            self._doc["invites"].append(inv)
            self._write()
            return dict(inv)

    def live_invites(self) -> list[dict]:
        """Unexpired invites, CLAIMED OR NOT — the ones a code may open.

        An invite is a link now, not a one-shot code, so being claimed does not
        retire it: the person it was sent to comes back to that same URL, and
        until they hold a passkey it is the only way they have in. What retires
        it is time (expiresAtTs) or an admin revoking it.
        """
        with self._lock:
            self._prune()
            return [dict(i) for i in self._doc["invites"]]

    def claim_invite(self, token_hash: str, user_id: str) -> bool:
        """Bind an unclaimed invite to the account its first use created.

        Idempotent by construction: a second call finds usedAt already set and
        changes nothing, so two tabs opening the same link cannot make two
        people out of one invite.
        """
        with self._lock:
            for inv in self._doc["invites"]:
                if inv["tokenHash"] == token_hash and not inv.get("usedAt"):
                    inv["usedAt"] = iso(now())
                    inv["usedBy"] = user_id
                    self._write()
                    return True
        return False

    def revoke_invite(self, token_hash: str) -> bool:
        with self._lock:
            before = len(self._doc["invites"])
            self._doc["invites"] = [i for i in self._doc["invites"] if i["tokenHash"] != token_hash]
            if len(self._doc["invites"]) == before:
                return False
            self._write()
            return True

    # ---- device links ------------------------------------------------------

    def add_link(self, token_hash: str, user_id: str) -> dict:
        """Mint a link code for one account, replacing any outstanding one.

        One live code per account, deliberately: a code that scrolled off
        someone's screen five minutes ago should not still open their account
        because they pressed the button twice.
        """
        with self._lock:
            self._doc["links"] = [link for link in self._doc["links"] if link["userId"] != user_id]
            link = {
                "tokenHash": token_hash,
                "userId": user_id,
                "createdAt": iso(now()),
                "expiresAtTs": now() + LINK_TTL_SECS,
            }
            self._doc["links"].append(link)
            self._write()
            return dict(link)

    def open_links(self) -> list[dict]:
        with self._lock:
            self._prune()
            return [dict(link) for link in self._doc["links"]]

    def consume_link(self, token_hash: str) -> str | None:
        """Spend a link code, returning the account it belongs to."""
        with self._lock:
            for link in self._doc["links"]:
                if link["tokenHash"] == token_hash and link.get("expiresAtTs", 0) > now():
                    self._doc["links"] = [other for other in self._doc["links"] if other["tokenHash"] != token_hash]
                    self._write()
                    return link["userId"]
        return None

    # ---- sessions ----------------------------------------------------------

    def new_session(self, user_id: str, ip: str, user_agent: str, max_expires_ts: int | None = None) -> str:
        """Create a session and return the token the browser will hold. Only its
        hash is persisted, so this is the last time the raw value exists here.

        `max_expires_ts` caps the lifetime. An account whose only credential is
        an invite link must not outlive that link: without the cap, opening the
        link on its last day would buy another 30 days, and "this invite is
        valid for 3 more days" would be a lie the visitor could disprove.
        """
        token = secrets.token_urlsafe(32)
        expires = now() + SESSION_TTL_SECS
        if max_expires_ts is not None:
            expires = min(expires, max_expires_ts)
        with self._lock:
            self._doc["sessions"].append(
                {
                    "tokenHash": _token_hash(token),
                    "userId": user_id,
                    "createdAt": iso(now()),
                    "expiresAtTs": expires,
                    "ip": ip,
                    "userAgent": user_agent[:200],
                }
            )
            self._prune()
            self._write()
        return token

    def session_user(self, token: str) -> dict | None:
        """Resolve a cookie token to its user, or None. Expired sessions resolve
        to None and are pruned on the next write.

        Resolving also TOUCHES `lastSeenAt` on the session and on its user, which
        is the only record that anybody used the gallery at all. Everything else
        here is an enrolment event: a new session is written on sign-in and a
        credential on passkey use, so a visitor holding a live cookie could
        browse for a month and leave no trace — "has Jukka been in lately?" was
        answerable only by inference from a 30-day-old session row (2026-08-24).

        The touch is THROTTLED to one write per SEEN_TOUCH_SECS per session: this
        runs on every gated request, and the state file is rewritten whole (with
        an fsync and a dated snapshot) on every write. Five-minute granularity is
        far finer than the question needs and costs one write per visitor per
        five minutes instead of one per image fetched.
        """
        if not token:
            return None
        wanted = _token_hash(token)
        with self._lock:
            for s in self._doc["sessions"]:
                if s["tokenHash"] == wanted and s.get("expiresAtTs", 0) > now():
                    user = self.user(s["userId"])
                    if user is not None:
                        self._touch_seen(s, user["id"])
                    return user
        return None

    def _touch_seen(self, session: dict, user_id: str) -> None:
        """Stamp lastSeenAt on a session and its user. Caller holds the lock."""
        t = now()
        if t - int(session.get("lastSeenTs") or 0) < SEEN_TOUCH_SECS:
            return
        session["lastSeenTs"] = t
        session["lastSeenAt"] = iso(t)
        for u in self._doc["users"]:
            if u["id"] == user_id:
                u["lastSeenAt"] = iso(t)
                break
        # The walk-in account index carries its own lastSeenAt because the idle
        # purge reads that index, not the user list.
        account = self._doc["walkin"]["accounts"].get(user_id)
        if account is not None:
            account["lastSeenAt"] = iso(t)
        self._write()

    def drop_session(self, token: str) -> None:
        if not token:
            return
        wanted = _token_hash(token)
        with self._lock:
            self._doc["sessions"] = [s for s in self._doc["sessions"] if s["tokenHash"] != wanted]
            self._write()

    def drop_user_sessions(self, user_id: str) -> None:
        with self._lock:
            self._doc["sessions"] = [s for s in self._doc["sessions"] if s["userId"] != user_id]
            self._write()

    # ---- generic access for satellite modules ------------------------------

    def snapshot(self) -> dict:
        """A deep copy of the whole document, taken under the lock."""
        with self._lock:
            return copy.deepcopy(self._doc)

    @contextmanager
    def mutate(self):
        """Yield the live document under the lock, persisting on a clean exit.

        walkin.py builds the whole walk-in surface — the switch, the account
        index, handle allocation — on top of this rather than growing a second
        state file. Handle allocation in particular MUST happen inside this
        lock: check-then-create is how two visitors end up as `bold-turing`
        (OPERATING-RULES rule 7).
        """
        with self._lock:
            yield self._doc
            self._write()

    def _prune(self) -> None:
        """Drop expired sessions, invites and device links. Caller holds the lock."""
        t = now()
        self._doc["sessions"] = [s for s in self._doc["sessions"] if s.get("expiresAtTs", 0) > t]
        # Expiry retires an invite whether or not it was claimed. A claimed one
        # used to be kept forever as a record, but now that it stays USABLE
        # until it expires, keeping it past that would leave a live-looking row
        # in the admin list for something that can no longer let anyone in.
        self._doc["invites"] = [i for i in self._doc["invites"] if i.get("expiresAtTs", 0) > t]
        self._doc["links"] = [link for link in self._doc["links"] if link.get("expiresAtTs", 0) > t]


def _migrate_walkin(doc: dict) -> None:
    """Add the walk-in keys to a document that predates them, in place.

    Tolerant on purpose: the live auth-state.json is the account database and
    must never be rewritten from scratch, so a missing key gains its default and
    a key of the wrong TYPE is replaced rather than crashing the service on
    start. Nothing is written here — the defaults reach the file on the first
    ordinary write, which is what "migrated in place" means.
    """
    block = doc.get("walkin")
    if not isinstance(block, dict):
        block = {}
    for key, default in WALKIN_DEFAULTS.items():
        value = block.get(key)
        if type(value) is not type(default):
            value = copy.deepcopy(default)
        block[key] = value
    doc["walkin"] = block

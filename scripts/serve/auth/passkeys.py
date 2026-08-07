"""WebAuthn ceremonies, wrapped around Yubico's fido2 (see ../requirements.in).

Yubico's library owns every cryptographic decision here — challenge generation,
attestation handling, origin/RP-ID binding, signature verification. This module
only adapts it to a stdlib HTTP server: JSON in and out, and a short-lived
server-side parking spot for the in-flight challenge.

Why the challenge is parked server-side rather than handed to the client: the
state fido2 returns carries the challenge that the response must match. Round-
tripping it through the browser would let a caller choose their own challenge,
which is the one thing a challenge may not be. So the client gets an opaque
ceremony id and nothing else.

Passkeys deliberately do NOT enforce the signature counter. Synced credentials
(iCloud Keychain, Google Password Manager, every platform authenticator that
matters here) report a counter of 0 forever, so a counter check would either be
dead code or lock out the exact devices this gallery is meant for.
"""

from __future__ import annotations

import enum
import secrets
import threading
import time
from collections.abc import Mapping

from fido2.server import Fido2Server
from fido2.utils import websafe_encode
from fido2.webauthn import (
    AttestedCredentialData,
    AuthenticationResponse,
    PublicKeyCredentialRpEntity,
    PublicKeyCredentialUserEntity,
    RegistrationResponse,
    ResidentKeyRequirement,
    UserVerificationRequirement,
)

CEREMONY_TTL_SECS = 300


def jsonable(value):
    """Convert fido2's mapping/enum/bytes soup into something json.dumps eats.

    fido2's option objects are Mappings whose leaves include raw bytes; WebAuthn
    on the wire wants those base64url-encoded, which is exactly what the browser
    side then decodes before calling navigator.credentials.
    """
    if isinstance(value, Mapping):
        return {k: jsonable(value[k]) for k in value}
    if isinstance(value, (list, tuple)):
        return [jsonable(v) for v in value]
    if isinstance(value, enum.Enum):
        return value.value
    if isinstance(value, bytes):
        return websafe_encode(value)
    return value


class Ceremonies:
    """Begin/finish for both WebAuthn ceremonies, plus the pending-state cache."""

    def __init__(self, rp_id: str, rp_name: str, origin: str):
        self.rp_id = rp_id
        self.origin = origin
        self._server = Fido2Server(
            PublicKeyCredentialRpEntity(id=rp_id, name=rp_name),
            attestation="none",
            # The gallery is one origin. Anything else presenting our RP ID is
            # not a deployment variant, it is an attack.
            verify_origin=lambda o: o == origin,
        )
        self._pending: dict[str, tuple] = {}
        self._lock = threading.Lock()

    # ---- pending ceremony state -------------------------------------------

    def _park(self, state, meta: dict) -> str:
        cid = secrets.token_urlsafe(18)
        with self._lock:
            self._expire()
            self._pending[cid] = (state, meta, time.time() + CEREMONY_TTL_SECS)
        return cid

    def _claim(self, cid: str):
        """Take a parked ceremony, removing it: one id is good for one attempt,
        so a replayed response cannot ride the same challenge twice."""
        with self._lock:
            self._expire()
            entry = self._pending.pop(cid or "", None)
        if not entry:
            return None, None
        state, meta, _ = entry
        return state, meta

    def _expire(self) -> None:
        t = time.time()
        self._pending = {k: v for k, v in self._pending.items() if v[2] > t}

    # ---- registration ------------------------------------------------------

    def begin_registration(self, user_id: bytes, name: str, display_name: str, existing: list, meta: dict):
        options, state = self._server.register_begin(
            PublicKeyCredentialUserEntity(id=user_id, name=name, display_name=display_name),
            existing,
            # A discoverable credential is what makes "just tap the key" login
            # possible: without it the server would have to know who you are
            # before you can prove it.
            resident_key_requirement=ResidentKeyRequirement.REQUIRED,
            user_verification=UserVerificationRequirement.PREFERRED,
        )
        cid = self._park(state, meta)
        return cid, jsonable(options)["publicKey"]

    def finish_registration(self, cid: str, response: dict):
        """Returns (AttestedCredentialData, meta). Raises on any failure — the
        caller turns that into one generic error, never a reason."""
        state, meta = self._claim(cid)
        if state is None:
            raise ValueError("unknown or expired ceremony")
        auth_data = self._server.register_complete(state, RegistrationResponse.from_dict(response))
        return auth_data.credential_data, meta

    # ---- authentication ----------------------------------------------------

    def begin_authentication(self, credentials: list):
        # No allowCredentials: the browser offers whatever discoverable
        # credential it holds for this RP, so login needs no username field.
        options, state = self._server.authenticate_begin(
            credentials, user_verification=UserVerificationRequirement.PREFERRED
        )
        cid = self._park(state, {})
        return cid, jsonable(options)["publicKey"]

    def finish_authentication(self, cid: str, response: dict, credentials: list):
        state, _ = self._claim(cid)
        if state is None:
            raise ValueError("unknown or expired ceremony")
        return self._server.authenticate_complete(state, credentials, AuthenticationResponse.from_dict(response))


def credential_from_b64(data_b64: str) -> AttestedCredentialData:
    """Rebuild a stored credential. The stored form is fido2's own serialization
    of the attested credential data, base64url, so nothing here parses COSE."""
    from fido2.utils import websafe_decode

    return AttestedCredentialData(websafe_decode(data_b64))


def credential_to_b64(cred: AttestedCredentialData) -> str:
    return websafe_encode(bytes(cred))


def credential_id_b64(cred: AttestedCredentialData) -> str:
    return websafe_encode(cred.credential_id)

"""Passkey auth for the publicly-reachable OS gallery.

The gallery's LAN origin stays open — this package only ever runs in front of the
public listener (see osgallery-https-server.py). Layout:

    codes.py     the 15-character invite/bootstrap codes people type
    store.py     the state file: users, passkeys, invites, sessions
    passkeys.py  WebAuthn ceremonies (python3-fido2)
    service.py   the policy — who gets in, who may invite, who may not be deleted
    routes.py    the /auth/* HTTP surface
    tickets.py   short-lived stream tickets for streamhost's media-plane gate
"""

from .service import AuthError, AuthService

__all__ = ["AuthError", "AuthService"]
